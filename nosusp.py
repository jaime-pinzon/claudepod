#!/usr/bin/env python3
"""
nosusp: run a command inside a PTY with the Ctrl+Z byte (0x1A) filtered out
of stdin so the child can never see it. Used to shield TUIs that install
their own raw-mode SIGTSTP handler (e.g., Claude Code) from being suspended
when there is no fallback shell to fg them back from.
"""
import fcntl
import os
import pty
import select
import signal
import sys
import termios
import tty


def _get_winsize(fd):
    return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\x00" * 8)


def _set_winsize(fd, winsize):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def main():
    if len(sys.argv) < 2:
        print("usage: nosusp command [args...]", file=sys.stderr)
        sys.exit(2)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    signal.signal(signal.SIGTSTP, signal.SIG_IGN)
    signal.signal(signal.SIGTTIN, signal.SIG_IGN)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)

    pid, master_fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        except OSError as e:
            print(f"nosusp: exec {sys.argv[1]!r} failed: {e}", file=sys.stderr)
            os._exit(127)

    old_attrs = None
    is_tty = False
    try:
        old_attrs = termios.tcgetattr(stdin_fd)
        tty.setraw(stdin_fd)
        is_tty = True
    except termios.error:
        pass

    if is_tty:
        try:
            _set_winsize(master_fd, _get_winsize(stdin_fd))
        except OSError:
            pass

        def _on_winch(_signum, _frame):
            try:
                _set_winsize(master_fd, _get_winsize(stdin_fd))
            except OSError:
                pass

        signal.signal(signal.SIGWINCH, _on_winch)

    try:
        stdin_closed = False
        while True:
            read_fds = [master_fd] + ([] if stdin_closed else [stdin_fd])
            try:
                rlist, _, _ = select.select(read_fds, [], [])
            except InterruptedError:
                continue
            except OSError:
                break

            if stdin_fd in rlist:
                try:
                    data = os.read(stdin_fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    stdin_closed = True
                else:
                    filtered = data.replace(b"\x1a", b"")
                    if filtered:
                        try:
                            os.write(master_fd, filtered)
                        except OSError:
                            break

            if master_fd in rlist:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                try:
                    os.write(stdout_fd, data)
                except OSError:
                    break
    finally:
        if old_attrs is not None:
            try:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)
            except termios.error:
                pass
        try:
            os.close(master_fd)
        except OSError:
            pass

    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        sys.exit(os.WEXITSTATUS(status))
    if os.WIFSIGNALED(status):
        sys.exit(128 + os.WTERMSIG(status))
    sys.exit(1)


if __name__ == "__main__":
    main()
