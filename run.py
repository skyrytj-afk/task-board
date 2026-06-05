#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task Board 로컬 런처
====================
desktop.html 을 로컬 서버(http://127.0.0.1:PORT)로 띄우고, 가능하면 앱 창으로 엽니다.

왜 이게 필요한가
  · 파일을 그냥 더블클릭(file://)하면 브라우저가 AI 호출을 CORS(origin: null)로 막을 수 있음.
  · localhost 로 띄우면 정상적인 http origin 이 되어 그 문제가 사라짐.

사내 AI 가 브라우저 CORS 를 막는 경우 (선택)
  · 환경변수 AI_TARGET 에 진짜 사내 API 주소를 넣고 실행하면,
    이 런처가 /proxy 로 받은 요청을 서버에서 그대로 사내 API로 전달(서버-서버라 CORS 무관).
  · 그 경우 앱의 ⚙️설정 > API 엔드포인트 URL 에 다음을 넣으세요:
        http://127.0.0.1:PORT/proxy        (PORT 는 실행 시 콘솔에 표시됨)
    토큰/모델/형식은 평소처럼 입력 → 헤더/본문은 그대로 사내 API로 전달됩니다.

사용법
  python run.py                # 기본 실행 (브라우저 자동 오픈)
  python run.py --port 8123    # 포트 지정
  python run.py --no-browser   # 브라우저 자동 오픈 안 함
  AI_TARGET=https://사내/v1/chat/completions python run.py   # CORS 우회 프록시 켜기

종료: 콘솔에서 Ctrl+C
"""
import argparse, functools, http.server, os, shutil, socket, subprocess, sys, threading, time, webbrowser
import urllib.request, urllib.error

DIR = os.path.dirname(os.path.abspath(__file__))
APP_FILE = "desktop.html"
AI_TARGET = os.environ.get("AI_TARGET", "").strip()
# 사내 API로 전달할 헤더 화이트리스트
FORWARD_HEADERS = ("content-type", "authorization", "x-api-key", "anthropic-version", "api-key", "openai-organization")


def find_free_port(preferred=0):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(("127.0.0.1", preferred or 0))
        except OSError:
            s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):  # 콘솔 조용히
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")

    def do_OPTIONS(self):
        if self.path.startswith("/proxy"):
            self.send_response(204); self._cors(); self.end_headers(); return
        self.send_response(204); self.end_headers()

    def do_POST(self):
        if self.path.startswith("/proxy"):
            return self._proxy()
        self.send_error(404, "Not found")

    def _proxy(self):
        if not AI_TARGET:
            self.send_response(503); self._cors()
            self.send_header("Content-Type", "application/json; charset=utf-8"); self.end_headers()
            self.wfile.write(b'{"error":"AI_TARGET env not set. \xec\x82\xac\xeb\x82\xb4 API \xec\xa3\xbc\xec\x86\x8c\xeb\xa5\xbc AI_TARGET \xec\x97\x90 \xeb\x84\xa3\xea\xb3\xa0 \xec\x8b\xa4\xed\x96\x89\xed\x95\x98\xec\x84\xb8\xec\x9a\x94."}')
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        req = urllib.request.Request(AI_TARGET, data=body, method="POST")
        for k, v in self.headers.items():
            if k.lower() in FORWARD_HEADERS:
                req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read(); status = r.status
                ctype = r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            data = e.read(); status = e.code; ctype = e.headers.get("Content-Type", "application/json")
        except Exception as e:
            data = ('{"error":"proxy failed: %s"}' % str(e)).encode("utf-8"); status = 502; ctype = "application/json"
        self.send_response(status); self._cors()
        self.send_header("Content-Type", ctype); self.end_headers()
        self.wfile.write(data)


def open_app_window(url):
    """크롬/엣지가 있으면 --app 창으로, 없으면 기본 브라우저로 연다."""
    candidates = []
    if sys.platform.startswith("win"):
        pf = os.environ.get("ProgramFiles", r"C:\Program Files")
        pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
        candidates = [
            shutil.which("chrome"), shutil.which("msedge"),
            os.path.join(pf, r"Google\Chrome\Application\chrome.exe"),
            os.path.join(pf86, r"Google\Chrome\Application\chrome.exe"),
            os.path.join(pf86, r"Microsoft\Edge\Application\msedge.exe"),
            os.path.join(pf, r"Microsoft\Edge\Application\msedge.exe"),
        ]
    elif sys.platform == "darwin":
        candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ]
    else:
        candidates = [shutil.which(b) for b in ("google-chrome", "chromium", "chromium-browser", "microsoft-edge")]

    for c in candidates:
        if c and os.path.exists(c):
            try:
                subprocess.Popen([c, "--app=" + url, "--new-window"])
                return c
            except Exception:
                continue
    webbrowser.open(url)  # 폴백
    return "default browser"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(DIR, APP_FILE)):
        print("오류: %s 가 이 폴더에 없습니다 (%s)" % (APP_FILE, DIR)); sys.exit(1)

    port = find_free_port(args.port)
    url = "http://127.0.0.1:%d/%s" % (port, APP_FILE)
    handler = functools.partial(Handler, directory=DIR)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)

    print("=" * 56)
    print(" Task Board 로컬 실행 중")
    print("   주소 : " + url)
    print("   AI 프록시 : " + ("ON  -> " + AI_TARGET + "  (앱 설정 URL: http://127.0.0.1:%d/proxy)" % port
                              if AI_TARGET else "OFF (AI_TARGET 미설정)"))
    print("   종료 : Ctrl+C")
    print("=" * 56)

    t = threading.Thread(target=httpd.serve_forever, daemon=True); t.start()
    if not args.no_browser:
        time.sleep(0.4)
        where = open_app_window(url)
        print(" 브라우저: " + str(where))
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n종료합니다."); httpd.shutdown()


if __name__ == "__main__":
    main()
