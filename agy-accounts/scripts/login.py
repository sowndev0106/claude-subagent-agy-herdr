#!/usr/bin/env python3
"""Đăng nhập agy cho một profile mà không mở giao diện lên màn hình.

Chạy agy trong một pty ẩn (khung rất rộng để link không bị ngắt dòng), tự chọn "Google OAuth",
in link đăng nhập, nhận mã xác thực (gõ vào nếu stdin là terminal, không thì đọc từ FIFO mà
`agy-p code` ghi vào), chờ agy ghi token rồi tắt agy.
Thoát 0 = đăng nhập xong, 3 = hết giờ chờ mã, 4 = đăng nhập không thành công.
"""
import argparse, base64, fcntl, json, os, pty, re, select, signal, struct, sys, termios, time

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>]")
OSC8 = re.compile(r"\x1b\]8;[^;]*;(https://accounts\.google\.com/[^\x07\x1b]+)(?:\x07|\x1b\\)")
PLAIN = re.compile(r"https://accounts\.google\.com/o/oauth2/\S+?[?&]state=[\w-]+(?=\s)")  # chỉ nhận link đã in trọn

a = argparse.ArgumentParser()
a.add_argument("--agy", required=True)
a.add_argument("--gemini-dir", required=True)
a.add_argument("--fifo")
a.add_argument("--timeout", type=int, default=900, help="giây chờ mã xác thực")
args = a.parse_args()
token_path = os.path.join(args.gemini_dir, "antigravity-cli", "antigravity-oauth-token")


def email():
    try:
        p = json.load(open(token_path))["id_token"].split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("email", "")
    except (OSError, ValueError, KeyError, IndexError):
        return ""


pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 4000, 0, 0))
    os.execvp(args.agy, [args.agy, f"--gemini_dir={args.gemini_dir}"])

raw = ""


def pump(timeout, extra=()):
    """Đọc output của agy (phải đọc liên tục để agy không bị nghẽn); trả về các fd khác đã sẵn sàng."""
    global raw
    r, _, _ = select.select([fd, *extra], [], [], timeout)
    if fd in r:
        try:
            raw += os.read(fd, 65536).decode("utf-8", "replace")
        except OSError:
            raise SystemExit(fail("agy đã thoát"))
    return [x for x in r if x != fd]


def text():
    return ANSI.sub("", raw)


def wait_for(pred, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        v = pred()
        if v:
            return v
        pump(0.5)
    raise SystemExit(fail(f"không thấy {what} sau {timeout}s"))


def stop():
    # agy là trưởng nhóm tiến trình (pty.fork → setsid): tín hiệu gửi cả nhóm để MCP server con (npm exec ...) cũng tắt
    for sig in (None, None, signal.SIGTERM, signal.SIGKILL):
        try:
            if sig is None:
                os.write(fd, b"\x03")
            else:
                os.killpg(pid, sig)
        except OSError:
            pass
        for _ in range(10):
            try:
                if os.waitpid(pid, os.WNOHANG)[0]:
                    break
            except ChildProcessError:
                break
            time.sleep(0.2)
        else:
            continue
        break
    try:
        os.killpg(pid, signal.SIGKILL)   # dọn tiến trình con còn sót trong nhóm sau khi agy đã thoát
    except OSError:
        pass


def fail(msg):
    tail = [l.strip() for l in text().splitlines() if l.strip()][-6:]
    print(f"LỖI: {msg}\n--- màn hình agy cuối ---\n" + "\n".join(tail), file=sys.stderr)
    stop()
    return 4


def on_signal(signum, _frame):  # bị tắt giữa chừng (Ctrl+C, kill): tắt luôn agy con, không để mồ côi
    stop()
    raise SystemExit(128 + signum)


for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, on_signal)

wait_for(lambda: "Select login method" in text(), 60, "màn hình chọn cách đăng nhập")
os.write(fd, b"\r")  # 1. Google OAuth


def find_url():  # ưu tiên link trong hyperlink OSC 8 ("Click here"), không có thì lấy chữ trên màn hình
    m = OSC8.search(raw)
    if m:
        return m[1]
    m = PLAIN.search(text())
    return m[0] if m else None


url = wait_for(find_url, 60, "link đăng nhập")
# luôn hiện bảng chọn account; không thì Google lấy luôn account mặc định của trình duyệt
url = url.replace("prompt=consent", "prompt=select_account%20consent", 1)
print(f"URL: {url}", flush=True)

# Nhận mã từ FIFO (agy-p code, chạy ở bất kỳ đâu) và, nếu là terminal, từ bàn phím: bên nào gửi trước thì dùng
src = []
if args.fifo:
    src.append(os.open(args.fifo, os.O_RDWR | os.O_NONBLOCK))  # O_RDWR: không bị EOF khi chưa có ai ghi
    print(f"Chờ mã: agy-p code <phiên> <mã>  (tối đa {args.timeout}s)", flush=True)
if sys.stdin.isatty():
    print("Hoặc dán mã xác thực ở đây rồi Enter: ", end="", flush=True)
    src.append(sys.stdin.fileno())
if not src:
    raise SystemExit(fail("không có chỗ nhận mã (cần terminal hoặc --fifo)"))

code, end = "", time.time() + args.timeout
while not code.endswith("\n"):
    if time.time() > end:
        stop()
        print("Hết giờ chờ mã xác thực", file=sys.stderr)
        raise SystemExit(3)
    for r in pump(0.5, src):
        code += os.read(r, 4096).decode("utf-8", "replace")
code = code.strip()
os.write(fd, code.encode())
time.sleep(0.3)
os.write(fd, b"\r")

e = wait_for(email, 90, "token sau khi dán mã (mã sai hoặc hết hạn?)")
stop()
print(f"OK {e}", flush=True)
