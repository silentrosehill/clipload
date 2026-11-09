"""Clipload for Windows — downloads videos and streams with yt-dlp.

Lives in the system tray, watches the clipboard for video links, takes clipload:// links
from the Stream Grabber userscript, and has a window with the download queue.
A port of the macOS app; it also runs on macOS/Linux for development.
"""

import datetime
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from urllib.parse import parse_qs, urlparse

from PySide6.QtCore import QDateTime, QLocale, QObject, QPoint, QProcess, QProcessEnvironment, QRect, QSettings, QSize, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QActionGroup, QBrush, QColor, QDesktopServices, QFont, QGuiApplication, QIcon, QImage, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMenu, QProgressBar, QPushButton,
    QSizePolicy, QSpinBox, QStackedWidget, QStyle, QSystemTrayIcon, QToolButton, QVBoxLayout, QWidget,
)

APP = "Clipload"
VERSION = "2.0"
IS_WIN = sys.platform == "win32"
IS_MAC = sys.platform == "darwin"

# MARK: - Settings

QUALITIES = [
    # key, label, short label, max height, yt-dlp format selector (prefers mp4/m4a so merging needs no re-encode)
    ("best", "Best available", "Best", None, "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b"),
    ("p2160", "Up to 4K (2160p)", "≤2160p", 2160, None),
    ("p1440", "Up to 1440p", "≤1440p", 1440, None),
    ("p1080", "Up to 1080p", "≤1080p", 1080, None),
    ("p720", "Up to 720p", "≤720p", 720, None),
    ("p480", "Up to 480p", "≤480p", 480, None),
    ("compatible", "Most compatible (H.264, ≤1080p)", "H.264", 1080,
     "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[vcodec^=avc1][height<=1080]/bv*[height<=1080]+ba/b"),
]
QUALITY = {q[0]: q for q in QUALITIES}


def quality_selector(key):
    _, _, _, h, sel = QUALITY[key]
    return sel or f"bv*[height<={h}][ext=mp4]+ba[ext=m4a]/bv*[height<={h}]+ba/b[height<={h}]/b"


AUDIO_SELECTOR = "ba[ext=m4a]/ba"

ASK_QUALITY = [("never", "Never (use default quality)"), ("streams", "For streams (HLS/DASH)"), ("always", "For every download")]
CLIP_MODES = [("ask", "Ask before downloading"), ("auto", "Download automatically"), ("off", "Do nothing")]


class Settings(QObject):
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.s = QSettings(APP, APP)
        if not self.s.value("token"):
            self.s.setValue("token", str(uuid.uuid4()).upper())

    def _get(self, key, default, kind=str):
        v = self.s.value(key, default)
        if kind is bool:
            return v in (True, "true", "1", 1)
        if kind is int:
            try:
                return int(v)
            except (TypeError, ValueError):
                return default
        return v

    def _set(self, key, value):
        self.s.setValue(key, value)
        self.changed.emit()

    quality = property(lambda self: self._get("quality", "best") if self._get("quality", "best") in QUALITY else "best",
                       lambda self, v: self._set("quality", v))
    ask_quality = property(lambda self: self._get("askQuality", "streams"), lambda self, v: self._set("askQuality", v))
    clip_mode = property(lambda self: self._get("clipMode", "ask"), lambda self, v: self._set("clipMode", v))
    any_link = property(lambda self: self._get("anyLink", False, bool), lambda self, v: self._set("anyLink", bool(v)))
    max_concurrent = property(lambda self: max(1, min(6, self._get("maxConcurrent", 3, int))),
                              lambda self, v: self._set("maxConcurrent", int(v)))
    folder = property(lambda self: self._get("folder", os.path.join(os.path.expanduser("~"), "Downloads", "Videos")),
                      lambda self, v: self._set("folder", v))
    token = property(lambda self: self._get("token", ""))


# MARK: - Tools and links

def app_dir():
    """Where Clipload.exe lives; the installer puts yt-dlp.exe and ffmpeg.exe next to it."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def find_tool(name):
    exe = name + (".exe" if IS_WIN else "")
    local = os.path.join(app_dir(), exe)
    if os.path.isfile(local):
        return local
    found = shutil.which(name)
    if found:
        return found
    for d in ("/opt/homebrew/bin", "/usr/local/bin"):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return None


def tool_environment():
    env = QProcessEnvironment.systemEnvironment()
    extra = [app_dir()] + ([] if IS_WIN else ["/opt/homebrew/bin", "/usr/local/bin"])
    env.insert("PATH", os.pathsep.join(extra + [env.value("PATH")]))
    env.insert("PYTHONIOENCODING", "utf-8")
    env.insert("PYTHONUTF8", "1")
    return env


VIDEO_HOSTS = [
    "youtube.com", "youtu.be", "vimeo.com", "x.com", "twitter.com", "tiktok.com",
    "instagram.com", "facebook.com", "fb.watch", "reddit.com", "redd.it", "twitch.tv",
    "dailymotion.com", "streamable.com", "bilibili.com", "bilibili.tv", "soundcloud.com",
    "bsky.app", "threads.net", "threads.com", "kick.com", "rumble.com", "9gag.com",
    "imgur.com", "vk.com", "ok.ru", "nicovideo.jp", "bandcamp.com", "loom.com",
    "pinterest.com", "tumblr.com", "archive.org", "ted.com", "odysee.com", "bitchute.com",
]
MEDIA_EXTENSIONS = {"mp4", "m4v", "mov", "webm", "mkv", "m3u8", "mpd", "mp3", "m4a"}


def path_ext(url):
    return os.path.splitext(url.path)[1].lstrip(".").lower()


def link_from(text):
    s = (text or "").strip()
    if not s or len(s) >= 2000 or any(c.isspace() for c in s):
        return None
    try:
        url = urlparse(s)
    except ValueError:
        return None
    if url.scheme.lower() not in ("http", "https") or not url.hostname:
        return None
    return s


def is_video_link(link):
    url = urlparse(link)
    if path_ext(url) in MEDIA_EXTENSIONS:
        return True
    host = (url.hostname or "").lower()
    # A bare homepage ("youtube.com/") is not a video.
    if len(url.path) <= 1 and not url.query:
        return False
    return any(host == h or host.endswith("." + h) for h in VIDEO_HOSTS)


def is_stream_link(link):
    s = link.lower()
    return path_ext(urlparse(link)) in ("m3u8", "mpd") or any(
        k in s for k in (".m3u8", ".mpd", "format=m3u8", "format=mpd"))


RESERVED_NAMES = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}


def file_safe(s):
    """Turns a page title into a file name that's valid on Windows and safe in a yt-dlp output template."""
    t = s.replace(":", " -").replace("\n", " ")
    t = re.sub(r'[<>"/\\|?*\x00-\x1f]', "-", t)
    t = t.replace("%", "%%").strip(" .")[:120].strip(" .")
    if not t:
        return "video"
    if t.split(".")[0].upper() in RESERVED_NAMES:
        t = "_" + t
    return t


def format_bytes(n):
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n} bytes" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1000


# MARK: - Requests, formats, jobs

class Request:
    """What to download. Streams sent from the browser also carry the page they played on
    (many HLS servers reject requests without the right Referer) and the page title."""

    def __init__(self, url, referer=None, title=None):
        self.url, self.referer, self.title = url, referer, title

    @property
    def host(self):
        return urlparse(self.url).hostname or ""

    def referer_args(self):
        if not self.referer:
            return []
        args = ["--referer", self.referer]
        r = urlparse(self.referer)
        if r.scheme and r.hostname:
            port = f":{r.port}" if r.port else ""
            args += ["--add-headers", f"Origin:{r.scheme}://{r.hostname}{port}"]
        return args


class StreamFormat:
    """One selectable quality, found by asking yt-dlp what the stream/page offers."""

    def __init__(self, id, height, fps, tbr, vcodec, has_audio, size):
        self.id, self.height, self.fps, self.tbr = id, height, fps, tbr
        self.vcodec, self.has_audio, self.size = vcodec, has_audio, size

    @property
    def codec_name(self):
        c = (self.vcodec or "").lower()
        if c.startswith(("avc", "h264")):
            return "H.264"
        if c.startswith("av01"):
            return "AV1"
        if c.startswith(("hvc", "hev", "h265")):
            return "HEVC"
        if c.startswith(("vp9", "vp09")):
            return "VP9"
        return None

    @property
    def resolution(self):
        return f"{self.height}p" + (str(round(self.fps)) if self.fps and self.fps > 31 else "")

    @property
    def label(self):
        parts = [self.resolution]
        if self.codec_name:
            parts.append(self.codec_name)
        if self.size:
            parts.append("~" + format_bytes(self.size))
        elif self.tbr:
            parts.append(f"{self.tbr / 1000:.1f} Mbps")
        return " · ".join(parts)

    @property
    def selector(self):
        return self.id if self.has_audio else f"{self.id}+ba/{self.id}"

    @property
    def codec_rank(self):
        return {"AV1": 3, "HEVC": 3, "H.264": 2, None: 2}.get(self.codec_name, 1)


def parse_formats(info):
    duration = info.get("duration")
    by_height = {}
    for f in info.get("formats") or []:
        vcodec = f.get("vcodec")
        h = f.get("height")
        fid = f.get("format_id")
        if vcodec == "none" or not h or h <= 0 or not fid:
            continue
        acodec = f.get("acodec")
        tbr = f.get("tbr")
        size = f.get("filesize") or f.get("filesize_approx")
        if not size and tbr and duration:
            size = int(tbr * 1000 / 8 * duration)
        fmt = StreamFormat(fid, int(h), f.get("fps"), tbr, vcodec, bool(acodec and acodec != "none"), size)
        cur = by_height.get(fmt.height)
        if cur and (cur.codec_rank, cur.tbr or 0) >= (fmt.codec_rank, fmt.tbr or 0):
            continue
        by_height[fmt.height] = fmt
    return sorted(by_height.values(), key=lambda f: -f.height)


PROBING, CHOOSING, QUEUED, RUNNING, DONE, FAILED, CANCELLED = "probing", "choosing", "queued", "running", "done", "failed", "cancelled"
FINISHED = {DONE, FAILED, CANCELLED}


class Job:
    def __init__(self, req, audio, quality, state=QUEUED):
        self.id = uuid.uuid4().hex
        self.req = req
        self.audio = audio
        self.title = req.title or req.host or req.url
        self.state = state
        self.percent = 0.0
        self.detail = ""
        self.file = None
        self.error = ""
        self.formats = []
        self.chosen = ""
        self.selector = AUDIO_SELECTOR if audio else quality_selector(quality)
        self.quality_label = "Audio" if audio else QUALITY[quality][2]
        self.process = None
        self.out_buffer = ""
        self.cancelled = False
        self.date = datetime.datetime.now()

    @property
    def finished(self):
        return self.state in FINISHED


def error_line(text):
    lines = [l for l in text.splitlines() if "ERROR" in l]
    return lines[-1].replace("ERROR: ", "").strip() if lines else None


def kill_process(p):
    """yt-dlp starts ffmpeg as a child, so on Windows end the whole process tree."""
    if p is None or p.state() == QProcess.NotRunning:
        return
    if IS_WIN:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.processId())],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=0x08000000)
    else:
        p.terminate()


# MARK: - Download manager

class Manager(QObject):
    changed = Signal()               # progress / counts changed
    needs_attention = Signal()       # a job wants a quality choice
    job_finished = Signal(object)

    def __init__(self, settings, notify):
        super().__init__()
        self.settings = settings
        self.notify = notify
        self.jobs = []               # newest first
        self.load_history()
        self.settings.changed.connect(self.pump)

    @property
    def running(self):
        return [j for j in self.jobs if j.state == RUNNING]

    def count(self, state):
        return sum(1 for j in self.jobs if j.state == state)

    # Adding

    def add(self, req, audio=False, quality=None):
        if not find_tool("yt-dlp"):
            self.notify("yt-dlp wasn't found", "Reinstall Clipload, or put yt-dlp.exe next to Clipload.exe.")
            return
        q = quality or self.settings.quality
        job = Job(req, audio, q)
        self.jobs.insert(0, job)
        ask = {"never": False, "streams": is_stream_link(req.url), "always": True}.get(self.settings.ask_quality, False)
        if ask and not audio:
            self.probe(job, q)
        else:
            self.pump()

    # Quality probing

    def _process(self, args):
        p = QProcess(self)
        p.setProgram(find_tool("yt-dlp"))
        p.setArguments(["--encoding", "utf-8"] + args)
        p.setProcessEnvironment(tool_environment())
        return p

    def probe(self, job, preferred):
        job.state = PROBING
        self.changed.emit()
        p = self._process(["-J", "--no-playlist", "--no-warnings"] + job.req.referer_args() + [job.req.url])
        job.process = p
        out, err = bytearray(), bytearray()
        p.readyReadStandardOutput.connect(lambda: out.extend(p.readAllStandardOutput().data()))
        p.readyReadStandardError.connect(lambda: err.extend(p.readAllStandardError().data()))

        def done(code, status):
            job.process = None
            p.deleteLater()
            if job.cancelled:
                return
            try:
                info = json.loads(out.decode("utf-8", "replace"))
            except ValueError:
                info = None
            if code != 0 or not isinstance(info, dict):
                self.fail(job, error_line(err.decode("utf-8", "replace")) or "No downloadable video found.")
                return
            if not job.req.title and info.get("title"):
                job.title = info["title"]
            formats = parse_formats(info)
            if len(formats) <= 1:
                # Nothing to choose between; go straight to the queue.
                job.state = QUEUED
                self.pump()
                return
            job.formats = formats
            target = QUALITY[preferred][3] or 10 ** 9
            job.chosen = next((f.id for f in formats if f.height <= target), formats[0].id)
            job.state = CHOOSING
            self.changed.emit()
            self.needs_attention.emit()

        p.finished.connect(done)
        p.errorOccurred.connect(lambda e: e == QProcess.FailedToStart and self.fail(job, "Couldn't start yt-dlp."))
        p.start()

    def confirm(self, job):
        f = next((f for f in job.formats if f.id == job.chosen), None)
        if job.state != CHOOSING or not f:
            return
        job.selector = f.selector
        job.quality_label = f.resolution
        job.state = QUEUED
        self.pump()

    # Queue

    def pump(self):
        slots = self.settings.max_concurrent - len(self.running)
        for job in reversed(self.jobs):   # oldest first
            if slots <= 0:
                break
            if job.state == QUEUED:
                self.run(job)
                slots -= 1
        self.changed.emit()

    def run(self, job):
        folder = self.settings.folder
        os.makedirs(folder, exist_ok=True)
        # Raw stream manifests have useless names ("master.m3u8"), so prefer the page title.
        name = f"{file_safe(job.req.title)}.%(ext)s" if job.req.title else "%(title).150B [%(id)s].%(ext)s"
        args = [
            "-P", folder,
            "-o", name,
            "--no-playlist", "--embed-metadata",
            "--concurrent-fragments", "8",
            "--newline", "--progress", "--color", "never",
            "--progress-template", "download:PROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:TITLE %(title)s",
            "--print", "after_move:FILE %(filepath)s",
            "-f", job.selector,
        ]
        ffmpeg = find_tool("ffmpeg")
        if ffmpeg:
            args += ["--ffmpeg-location", ffmpeg]
        args += ["-x", "--audio-format", "m4a"] if job.audio else ["--merge-output-format", "mp4"]
        args += job.req.referer_args()
        args.append(job.req.url)

        p = self._process(args)
        p.readyReadStandardOutput.connect(lambda: self.handle_output(p.readAllStandardOutput().data(), job))

        def on_err():
            line = error_line(p.readAllStandardError().data().decode("utf-8", "replace"))
            if line:
                job.error = line

        p.readyReadStandardError.connect(on_err)
        p.finished.connect(lambda code, status: self.finished(job, p, code))
        p.errorOccurred.connect(lambda e: e == QProcess.FailedToStart and self.finished(job, p, -1))

        job.process = p
        job.state = RUNNING
        job.percent = 0
        job.detail = "Starting…"
        job.error = ""
        job.out_buffer = ""
        p.start()

    def handle_output(self, data, job):
        job.out_buffer += data.decode("utf-8", "replace")
        *lines, job.out_buffer = job.out_buffer.split("\n")
        for line in lines:
            line = line.rstrip("\r")
            if line.startswith("PROG"):
                parts = [x.strip() for x in line[4:].split("|")]
                try:
                    job.percent = float(parts[0].replace("%", ""))
                except ValueError:
                    pass
                speed = parts[1] if len(parts) > 1 else ""
                eta = parts[2] if len(parts) > 2 else ""
                bits = []
                if speed and "Unknown" not in speed and speed != "N/A":
                    bits.append(speed)
                if eta and "Unknown" not in eta and eta != "N/A":
                    bits.append(f"{eta} left")
                job.detail = " · ".join(bits)
            elif line.startswith("TITLE ") and not job.req.title:
                job.title = line[6:]
            elif line.startswith("FILE "):
                job.file = line[5:]
        self.changed.emit()

    def finished(self, job, p, code):
        if job.process is not p:
            return
        job.process = None
        p.deleteLater()
        if job.cancelled:
            job.state = CANCELLED
        elif code == 0 and job.file:
            job.state = DONE
            job.percent = 100
            job.date = datetime.datetime.now()
            self.save_history()
            self.job_finished.emit(job)
        else:
            self.fail(job, job.error or "No downloadable video found on that page.")
            return
        self.pump()

    def fail(self, job, message):
        job.process = None
        job.state = FAILED
        job.error = message
        self.job_finished.emit(job)
        self.pump()

    # User actions

    def cancel(self, job):
        if job.state in (RUNNING, PROBING):
            job.cancelled = True
            kill_process(job.process)
            if job.state == PROBING:
                job.state = CANCELLED
        elif job.state in (QUEUED, CHOOSING):
            job.state = CANCELLED
        self.pump()

    def cancel_all(self):
        for j in [j for j in self.jobs if not j.finished]:
            self.cancel(j)

    def retry(self, job):
        if job.state not in (FAILED, CANCELLED):
            return
        job.cancelled = False
        job.error = ""
        job.percent = 0
        job.state = QUEUED
        self.pump()

    def remove(self, job):
        if not job.finished:
            self.cancel(job)
        self.jobs = [j for j in self.jobs if j is not job]
        self.save_history()
        self.changed.emit()

    def clear_finished(self):
        self.jobs = [j for j in self.jobs if not j.finished]
        self.save_history()
        self.changed.emit()

    # History (finished downloads are remembered between launches)

    def save_history(self):
        saved = [{"title": j.title, "file": j.file, "url": j.req.url, "date": j.date.isoformat()}
                 for j in self.jobs if j.state == DONE and j.file][:100]
        self.settings.s.setValue("history", json.dumps(saved))

    def load_history(self):
        try:
            saved = json.loads(self.settings.s.value("history", "[]"))
        except (TypeError, ValueError):
            return
        for s in saved:
            j = Job(Request(s["url"], title=s["title"]), False, "best", DONE)
            j.file = s["file"]
            j.percent = 100
            try:
                j.date = datetime.datetime.fromisoformat(s["date"])
            except (KeyError, ValueError):
                pass
            self.jobs.append(j)

    # Maintenance

    def update_ytdlp(self):
        """Sites change their players often; a fresh yt-dlp fixes most failures."""
        ytdlp = find_tool("yt-dlp")
        if not ytdlp:
            self.notify("yt-dlp wasn't found", "Reinstall Clipload.")
            return
        brew = next((b for b in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew") if os.path.isfile(b)), None)
        if brew and ytdlp.startswith(os.path.dirname(os.path.dirname(brew))):
            program, args = brew, ["upgrade", "yt-dlp"]
        else:
            program, args = ytdlp, ["-U"]
        self.notify("Updating yt-dlp…", "This can take a minute.", timeout=0)
        p = QProcess(self)
        p.setProgram(program)
        p.setArguments(args)
        p.setProcessEnvironment(tool_environment())

        def done(code, status):
            text = p.readAll().data().decode("utf-8", "replace")
            p.deleteLater()
            if code == 0:
                self.notify("yt-dlp is up to date", "Try the download again.")
            else:
                lines = text.strip().splitlines()
                self.notify("Update failed", error_line(text) or (lines[-1] if lines else ""))

        p.setProcessChannelMode(QProcess.MergedChannels)
        p.finished.connect(done)
        p.start()


# MARK: - Icons

def draw_app_icon(px):
    """Clipload's icon: a blue/purple rounded square with a white arrow into a tray."""
    img = QImage(px, px, QImage.Format_ARGB32_Premultiplied)
    img.fill(Qt.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    s = float(px)
    inset = s * (0.098 if px >= 64 else 0.03)
    w = s - 2 * inset
    path = QPainterPath()
    path.addRoundedRect(inset, inset, w, w, w * 0.225, w * 0.225)
    g = QLinearGradient(0, inset, 0, inset + w)
    g.setColorAt(0, QColor.fromRgbF(0.36, 0.62, 1.00))
    g.setColorAt(0.5, QColor.fromRgbF(0.22, 0.38, 0.98))
    g.setColorAt(1, QColor.fromRgbF(0.45, 0.26, 0.93))
    p.fillPath(path, QBrush(g))

    pen = QPen(Qt.white, w * 0.085, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
    p.setPen(pen)
    cx = inset + w / 2
    y = lambda frac_from_bottom: inset + w - frac_from_bottom * w   # noqa: E731
    p.drawLine(QPoint(round(cx), round(y(0.78))), QPoint(round(cx), round(y(0.38))))
    head = QPainterPath()
    head.moveTo(cx - w * 0.17, y(0.53))
    head.lineTo(cx, y(0.36))
    head.lineTo(cx + w * 0.17, y(0.53))
    p.drawPath(head)
    tray = QPainterPath()
    tray.moveTo(cx - w * 0.27, y(0.30))
    tray.lineTo(cx - w * 0.27, y(0.21))
    tray.lineTo(cx + w * 0.27, y(0.21))
    tray.lineTo(cx + w * 0.27, y(0.30))
    p.drawPath(tray)
    p.end()
    return img


def app_icon():
    icon = QIcon()
    for size in (16, 20, 24, 32, 40, 48, 64, 128, 256):
        icon.addPixmap(QPixmap.fromImage(draw_app_icon(size)))
    return icon


def tray_icon(percent=None, paused=False):
    """The app icon, with a progress bar along the bottom while downloading."""
    img = draw_app_icon(64)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    if percent is not None:
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(0, 0, 0, 170))
        p.drawRoundedRect(QRect(2, 50, 60, 12), 5, 5)
        p.setBrush(QColor("#4ade80"))
        p.drawRoundedRect(QRect(4, 52, max(6, int(56 * percent / 100)), 8), 4, 4)
    elif paused:
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(60, 60, 60, 230))
        p.drawEllipse(QRect(36, 36, 28, 28))
        p.setBrush(Qt.white)
        p.drawRect(QRect(44, 43, 4, 14))
        p.drawRect(QRect(52, 43, 4, 14))
    p.end()
    return QIcon(QPixmap.fromImage(img))


STATE_STYLE = {
    PROBING: ("#8b8b8b", "…"), CHOOSING: ("#3b82f6", "⇅"), QUEUED: ("#8b8b8b", "⏱"),
    RUNNING: ("#3b82f6", "↓"), DONE: ("#22c55e", "✓"), FAILED: ("#f59e0b", "!"), CANCELLED: ("#9ca3af", "✕"),
}
_state_cache = {}


def state_pixmap(state, audio=False, ratio=1.0):
    key = (state, audio, ratio)
    if key not in _state_cache:
        color, glyph = STATE_STYLE[state]
        if state == DONE and audio:
            glyph = "♪"
        size = 28
        pm = QPixmap(int(size * ratio), int(size * ratio))
        pm.setDevicePixelRatio(ratio)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(color))
        p.drawEllipse(QRect(2, 2, size - 4, size - 4))
        p.setPen(Qt.white)
        f = QFont()
        f.setPixelSize(15)
        f.setBold(True)
        p.setFont(f)
        p.drawText(QRect(0, 0, size, size - 1), Qt.AlignCenter, glyph)
        p.end()
        _state_cache[key] = pm
    return _state_cache[key]


# MARK: - Toast

class Toast(QWidget):
    """Small pop-up near the tray that doesn't steal focus."""

    def __init__(self):
        super().__init__(None, Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.timer = QTimer(self, singleShot=True, timeout=self.hide)
        self.frame = QFrame(self)
        self.frame.setObjectName("toast")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(8, 8, 8, 8)
        outer.addWidget(self.frame)
        self.box = QVBoxLayout(self.frame)
        self.box.setContentsMargins(14, 12, 14, 12)
        self.box.setSpacing(6)
        self.setFixedWidth(370)

    def show_message(self, title, subtitle, buttons=(), timeout=8):
        dark = QGuiApplication.styleHints().colorScheme() == Qt.ColorScheme.Dark
        bg, fg, sub, border = ("#2b2b2b", "#ffffff", "#bdbdbd", "#3d3d3d") if dark else ("#fbfbfb", "#1a1a1a", "#5f5f5f", "#d0d0d0")
        self.frame.setStyleSheet(f"#toast {{ background: {bg}; border: 1px solid {border}; border-radius: 10px; }}"
                                 f"QLabel {{ color: {fg}; background: transparent; }} QLabel#sub {{ color: {sub}; }}")
        while self.box.count():
            item = self.box.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
            elif item.layout():
                lay = item.layout()
                while lay.count():
                    w = lay.takeAt(0).widget()
                    if w:
                        w.deleteLater()
        t = QLabel(title)
        f = t.font()
        f.setBold(True)
        f.setPointSizeF(f.pointSizeF() + 1)
        t.setFont(f)
        self.box.addWidget(t)
        if subtitle:
            s = QLabel(QLabel().fontMetrics().elidedText(subtitle, Qt.ElideMiddle, 330 * 2))
            s.setObjectName("sub")
            s.setWordWrap(True)
            s.setMaximumWidth(330)
            self.box.addWidget(s)
        row = QHBoxLayout()
        row.setSpacing(6)
        for i, (label, action) in enumerate(list(buttons) + [("Dismiss", None)]):
            b = QPushButton(label)
            b.setFocusPolicy(Qt.NoFocus)
            b.setDefault(i == 0 and action is not None)
            b.clicked.connect(lambda _=False, a=action: (self.hide(), a and a()))
            row.addWidget(b)
        row.addStretch()
        self.box.addLayout(row)

        self.adjustSize()
        screen = (QGuiApplication.screenAt(QGuiApplication.primaryScreen().geometry().center())
                  or QGuiApplication.primaryScreen()).availableGeometry()
        # Windows: bottom-right, above the taskbar. macOS: top-right, under the menu bar.
        y = screen.top() + 4 if IS_MAC else screen.bottom() - self.height() - 4
        self.move(screen.right() - self.width() - 4, y)
        self.show()
        self.raise_()
        if timeout > 0:
            self.timer.start(int(timeout * 1000))
        else:
            self.timer.stop()


# MARK: - Main window

class ElidedLabel(QLabel):
    def __init__(self, mode=Qt.ElideRight):
        super().__init__()
        self.mode = mode
        self.full = ""
        self.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)

    def set_full_text(self, text):
        if text != self.full:
            self.full = text
            self.setText(text)
            self.setToolTip(text)

    def paintEvent(self, e):
        p = QPainter(self)
        p.setPen(self.palette().color(self.foregroundRole()))
        p.setFont(self.font())
        p.drawText(self.rect(), Qt.AlignLeft | Qt.AlignVCenter,
                   self.fontMetrics().elidedText(self.full, self.mode, self.width()))


def tool_button(icon, tip, action):
    b = QToolButton()
    b.setIcon(icon)
    b.setIconSize(QSize(18, 18))
    b.setAutoRaise(True)
    b.setToolTip(tip)
    b.clicked.connect(action)
    return b


def std_icon(name):
    return QApplication.style().standardIcon(getattr(QStyle.StandardPixmap, name))


def open_file(path):
    QDesktopServices.openUrl(QUrl.fromLocalFile(path))


def reveal(path):
    if IS_WIN:
        subprocess.Popen(["explorer", "/select,", os.path.normpath(path)])
    elif IS_MAC:
        subprocess.Popen(["open", "-R", path])
    else:
        open_file(os.path.dirname(path))


class JobRow(QWidget):
    def __init__(self, job, manager):
        super().__init__()
        self.job, self.manager = job, manager
        self.shown_state = None
        lay = QHBoxLayout(self)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(12)
        self.icon = QLabel()
        self.icon.setFixedSize(28, 28)
        lay.addWidget(self.icon)

        mid = QVBoxLayout()
        mid.setSpacing(3)
        self.title = ElidedLabel(Qt.ElideMiddle)
        f = self.title.font()
        f.setBold(True)
        self.title.setFont(f)
        mid.addWidget(self.title)
        self.progress = QProgressBar()
        self.progress.setRange(0, 1000)
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(6)
        # Keep the row height the same whether or not the bar is showing.
        sp = self.progress.sizePolicy()
        sp.setRetainSizeWhenHidden(True)
        self.progress.setSizePolicy(sp)
        mid.addWidget(self.progress)
        self.status = ElidedLabel()
        sf = self.status.font()
        sf.setPointSizeF(sf.pointSizeF() - 1)
        self.status.setFont(sf)
        mid.addWidget(self.status)
        lay.addLayout(mid, 1)

        self.controls = QHBoxLayout()
        self.controls.setSpacing(4)
        lay.addLayout(self.controls)
        self.setContextMenuPolicy(Qt.CustomContextMenu)
        self.customContextMenuRequested.connect(self.context_menu)
        self.refresh()

    def refresh(self):
        job = self.job
        self.icon.setPixmap(state_pixmap(job.state, job.audio, self.devicePixelRatioF()))
        self.title.set_full_text(job.title)
        self.progress.setVisible(job.state == RUNNING)
        self.progress.setValue(int(max(0, min(job.percent, 100)) * 10))
        self.status.set_full_text(self.status_text())
        pal = self.status.palette()
        pal.setColor(self.status.foregroundRole(),
                     QColor("#dc2626") if job.state == FAILED else self.palette().color(self.palette().ColorGroup.Disabled, self.palette().ColorRole.WindowText))
        self.status.setPalette(pal)
        if job.state != self.shown_state:
            self.shown_state = job.state
            self.build_controls()

    def status_text(self):
        job = self.job
        host = job.req.host
        if job.state == PROBING:
            return f"Checking available qualities… · {host}"
        if job.state == CHOOSING:
            return f"Choose a quality · {len(job.formats)} available · {host}"
        if job.state == QUEUED:
            return f"Queued · {job.quality_label} · {host}"
        if job.state == RUNNING:
            return " · ".join(x for x in (f"{int(job.percent)}%", job.quality_label, job.detail) if x)
        if job.state == DONE:
            parts = ["Done"]
            if job.file and os.path.isfile(job.file):
                parts.append(format_bytes(os.path.getsize(job.file)))
            elif job.file:
                parts.append("file moved or deleted")
            dt = QDateTime.fromSecsSinceEpoch(int(job.date.timestamp()))
            parts.append(QLocale().toString(dt, QLocale.ShortFormat))
            return " · ".join(parts)
        if job.state == FAILED:
            return job.error
        return "Cancelled"

    def build_controls(self):
        while self.controls.count():
            w = self.controls.takeAt(0).widget()
            if w:
                w.deleteLater()
        job, m = self.job, self.manager
        if job.state == CHOOSING:
            combo = QComboBox()
            for f in job.formats:
                combo.addItem(f.label, f.id)
            combo.setCurrentIndex(max(0, combo.findData(job.chosen)))
            combo.currentIndexChanged.connect(lambda i: setattr(job, "chosen", combo.itemData(i)))
            combo.setMinimumWidth(220)
            self.controls.addWidget(combo)
            dl = QPushButton("Download")
            dl.setDefault(True)
            dl.clicked.connect(lambda: m.confirm(job))
            self.controls.addWidget(dl)
            self.controls.addWidget(tool_button(std_icon("SP_DialogCancelButton"), "Cancel", lambda: m.cancel(job)))
        elif job.state in (PROBING, QUEUED, RUNNING):
            self.controls.addWidget(tool_button(std_icon("SP_DialogCancelButton"), "Cancel", lambda: m.cancel(job)))
        elif job.state == DONE and job.file:
            self.controls.addWidget(tool_button(std_icon("SP_MediaPlay"), "Open", lambda: open_file(job.file)))
            self.controls.addWidget(tool_button(std_icon("SP_DirOpenIcon"), "Show in folder", lambda: reveal(job.file)))
        elif job.state in (FAILED, CANCELLED):
            self.controls.addWidget(tool_button(std_icon("SP_BrowserReload"), "Retry", lambda: m.retry(job)))
            self.controls.addWidget(tool_button(std_icon("SP_TrashIcon"), "Remove from list", lambda: m.remove(job)))

    def context_menu(self, pos):
        job = self.job
        menu = QMenu(self)
        menu.addAction("Copy Link", lambda: QGuiApplication.clipboard().setText(job.req.url))
        if job.state == DONE and job.file:
            menu.addAction("Show in Folder", lambda: reveal(job.file))
            menu.addAction("Open", lambda: open_file(job.file))
        menu.addSeparator()
        menu.addAction("Remove from List", lambda: self.manager.remove(job))
        menu.exec(self.mapToGlobal(pos))


class MainWindow(QMainWindow):
    def __init__(self, manager, settings, on_close):
        super().__init__()
        self.manager, self.settings, self.on_close = manager, settings, on_close
        self.rows = {}
        self.setWindowTitle(APP)
        self.setMinimumSize(700, 420)
        self.resize(780, 540)

        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        top = QHBoxLayout()
        top.setContentsMargins(12, 12, 12, 12)
        top.setSpacing(8)
        self.link = QLineEdit()
        self.link.setPlaceholderText("Paste a video page or stream link…")
        self.link.setClearButtonEnabled(True)
        self.link.returnPressed.connect(self.download)
        self.link.textChanged.connect(self.update_button)
        top.addWidget(self.link, 1)
        self.quality = QComboBox()
        for key, label, *_ in QUALITIES:
            self.quality.addItem(label, key)
        self.quality.setCurrentIndex(self.quality.findData(settings.quality))
        top.addWidget(self.quality)
        self.audio = QCheckBox("Audio only")
        self.audio.toggled.connect(lambda on: self.quality.setEnabled(not on))
        top.addWidget(self.audio)
        self.dl = QPushButton("Download")
        self.dl.setDefault(True)
        self.dl.clicked.connect(self.download)
        top.addWidget(self.dl)
        root.addLayout(top)
        root.addWidget(self.hline())

        self.stack = QStackedWidget()
        empty = QWidget()
        el = QVBoxLayout(empty)
        el.addStretch()
        pic = QLabel()
        pic.setPixmap(QPixmap.fromImage(draw_app_icon(int(72 * self.devicePixelRatioF()))).scaled(
            72, 72, Qt.KeepAspectRatio, Qt.SmoothTransformation))
        pic.setAlignment(Qt.AlignCenter)
        el.addWidget(pic)
        head = QLabel("No downloads yet")
        hf = head.font()
        hf.setPointSizeF(hf.pointSizeF() + 4)
        hf.setBold(True)
        head.setFont(hf)
        head.setAlignment(Qt.AlignCenter)
        el.addWidget(head)
        hint = QLabel("Paste a link above, copy a video link anywhere,\nor click ⬇ Stream on a video in your browser.")
        hint.setAlignment(Qt.AlignCenter)
        hint.setEnabled(False)
        el.addWidget(hint)
        el.addStretch()
        self.stack.addWidget(empty)
        self.list = QListWidget()
        self.list.setFrameShape(QFrame.NoFrame)
        self.list.setSelectionMode(QListWidget.NoSelection)
        self.list.setFocusPolicy(Qt.NoFocus)
        self.list.setVerticalScrollMode(QListWidget.ScrollPerPixel)
        self.list.setStyleSheet("QListWidget::item { border-bottom: 1px solid palette(midlight); }")
        self.stack.addWidget(self.list)
        root.addWidget(self.stack, 1)
        root.addWidget(self.hline())

        bottom = QHBoxLayout()
        bottom.setContentsMargins(12, 6, 8, 6)
        self.summary = QLabel()
        self.summary.setEnabled(False)
        bottom.addWidget(self.summary, 1)
        self.clear = QPushButton("Clear finished")
        self.clear.setFlat(True)
        self.clear.clicked.connect(manager.clear_finished)
        bottom.addWidget(self.clear)
        bottom.addWidget(tool_button(std_icon("SP_DirIcon"), "Open download folder", self.open_folder))
        gear = tool_button(std_icon("SP_FileDialogDetailedView"), "Settings (Ctrl+,)", self.show_settings)
        gear.setShortcut("Ctrl+,")
        bottom.addWidget(gear)
        root.addLayout(bottom)

        self.setCentralWidget(central)
        self.refresh_timer = QTimer(self, singleShot=True, interval=60, timeout=self.refresh)
        manager.changed.connect(self.refresh_timer.start)
        settings.changed.connect(self.refresh_timer.start)
        self.update_button()
        self.refresh()

    @staticmethod
    def hline():
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setFrameShadow(QFrame.Sunken)
        return line

    def update_button(self):
        self.dl.setEnabled(link_from(self.link.text()) is not None)

    def download(self):
        url = link_from(self.link.text())
        if not url:
            return
        self.manager.add(Request(url), audio=self.audio.isChecked(), quality=self.quality.currentData())
        self.link.clear()

    def open_folder(self):
        os.makedirs(self.settings.folder, exist_ok=True)
        open_file(self.settings.folder)

    def show_settings(self):
        SettingsDialog(self.settings, self.manager, self).exec()

    def refresh(self):
        jobs = self.manager.jobs
        self.stack.setCurrentIndex(1 if jobs else 0)
        ids = [j.id for j in jobs]
        # Drop rows for removed jobs.
        for jid in [k for k in self.rows if k not in ids]:
            item, _ = self.rows.pop(jid)
            self.list.takeItem(self.list.row(item))
        # Add new rows (newest first) and update the rest.
        for i, job in enumerate(jobs):
            if job.id not in self.rows:
                item = QListWidgetItem()
                row = JobRow(job, self.manager)
                self.list.insertItem(i, item)
                self.list.setItemWidget(item, row)
                self.rows[job.id] = (item, row)
            item, row = self.rows[job.id]
            row.refresh()
            hint = row.sizeHint()
            if item.sizeHint() != hint:
                item.setSizeHint(hint)
        self.clear.setEnabled(any(j.finished for j in jobs))
        self.summary.setText(self.summary_text())

    def summary_text(self):
        m = self.manager
        parts = []
        if m.running:
            parts.append(f"{len(m.running)} downloading")
        if m.count(QUEUED):
            parts.append(f"{m.count(QUEUED)} queued")
        if m.count(CHOOSING):
            parts.append(f"{m.count(CHOOSING)} waiting for a quality")
        limit = f"up to {self.settings.max_concurrent} at a time"
        return " · ".join(parts + [limit]) if parts else f"Idle · {limit}"

    def closeEvent(self, e):
        # Closing the window keeps Clipload running in the tray.
        e.ignore()
        self.hide()
        self.on_close()


# MARK: - Settings

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def launch_command(*args):
    if getattr(sys, "frozen", False):
        parts = [sys.executable]
    else:
        exe = sys.executable
        if IS_WIN:
            exe = exe.replace("python.exe", "pythonw.exe")
        parts = [exe, os.path.abspath(__file__)]
    return " ".join(f'"{p}"' for p in parts + list(args))


def login_item_enabled():
    if not IS_WIN:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP)
            return True
    except OSError:
        return False


def set_login_item(on):
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, APP, 0, winreg.REG_SZ, launch_command("--background"))
        else:
            try:
                winreg.DeleteValue(k, APP)
            except FileNotFoundError:
                pass


def register_url_scheme():
    """Makes clipload:// links (from the Stream Grabber userscript) open this app."""
    if not IS_WIN:
        return
    import winreg
    base = r"Software\Classes\clipload"
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, base) as k:
        winreg.SetValueEx(k, None, 0, winreg.REG_SZ, "URL:Clipload")
        winreg.SetValueEx(k, "URL Protocol", 0, winreg.REG_SZ, "")
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, base + r"\shell\open\command") as k:
        winreg.SetValueEx(k, None, 0, winreg.REG_SZ, launch_command("%1"))


class SettingsDialog(QDialog):
    def __init__(self, settings, manager, parent):
        super().__init__(parent)
        self.s = settings
        self.setWindowTitle("Clipload Settings")
        self.setMinimumWidth(520)
        lay = QVBoxLayout(self)

        dl = QGroupBox("Downloads")
        f = QFormLayout(dl)
        self.quality = self.combo([(k, l) for k, l, *_ in QUALITIES], settings.quality, lambda v: setattr(settings, "quality", v))
        f.addRow("Default quality", self.quality)
        f.addRow("Let me pick the quality", self.combo(ASK_QUALITY, settings.ask_quality, lambda v: setattr(settings, "ask_quality", v)))
        spin = QSpinBox()
        spin.setRange(1, 6)
        spin.setValue(settings.max_concurrent)
        spin.setSuffix(" at a time")
        spin.valueChanged.connect(lambda v: setattr(settings, "max_concurrent", v))
        f.addRow("Downloads", spin)
        folder_row = QHBoxLayout()
        self.folder = ElidedLabel(Qt.ElideMiddle)
        self.folder.set_full_text(settings.folder)
        folder_row.addWidget(self.folder, 1)
        change = QPushButton("Change…")
        change.clicked.connect(self.choose_folder)
        folder_row.addWidget(change)
        f.addRow("Save to", folder_row)
        lay.addWidget(dl)

        clip = QGroupBox("Clipboard")
        f = QFormLayout(clip)
        f.addRow("When I copy a video link", self.combo(CLIP_MODES, settings.clip_mode, lambda v: setattr(settings, "clip_mode", v)))
        any_link = QCheckBox("Offer for any link, not just video sites")
        any_link.setChecked(settings.any_link)
        any_link.toggled.connect(lambda on: setattr(settings, "any_link", on))
        f.addRow(any_link)
        lay.addWidget(clip)

        gen = QGroupBox("General")
        f = QFormLayout(gen)
        if IS_WIN:
            login = QCheckBox("Open at login")
            login.setChecked(login_item_enabled())
            login.toggled.connect(set_login_item)
            f.addRow(login)
        token_row = QHBoxLayout()
        copy = QPushButton("Copy token")
        copy.setToolTip("Paste it into the Stream Grabber userscript so its downloads start without asking.")
        copy.clicked.connect(lambda: (QGuiApplication.clipboard().setText(settings.token), copy.setText("Copied")))
        token_row.addWidget(copy)
        token_row.addStretch()
        f.addRow("Stream Grabber", token_row)
        update = QPushButton("Update")
        update.clicked.connect(manager.update_ytdlp)
        urow = QHBoxLayout()
        urow.addWidget(update)
        urow.addStretch()
        f.addRow("yt-dlp", urow)
        lay.addWidget(gen)

        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        lay.addWidget(buttons)

    @staticmethod
    def combo(items, current, on_change):
        c = QComboBox()
        for key, label in items:
            c.addItem(label, key)
        c.setCurrentIndex(max(0, c.findData(current)))
        c.currentIndexChanged.connect(lambda i: on_change(c.itemData(i)))
        return c

    def choose_folder(self):
        d = QFileDialog.getExistingDirectory(self, "Save downloads to", self.s.folder)
        if d:
            self.s.folder = os.path.normpath(d)
            self.folder.set_full_text(self.s.folder)


# MARK: - App

SECRET_FORMATS = (
    "ExcludeClipboardContentFromMonitorProcessing",   # Windows password managers
    "CanIncludeInClipboardHistory",
    "org.nspasteboard.ConcealedType",                  # macOS password managers
    "org.nspasteboard.TransientType",
)


class Clipload(QObject):
    def __init__(self, app, background):
        super().__init__()
        self.app = app
        self.settings = Settings()
        self.toast = Toast()
        self.manager = Manager(self.settings, self.notify)
        self.window = MainWindow(self.manager, self.settings, self.window_closed)
        self.window.setWindowIcon(app_icon())
        self.last_offered = ""

        self.tray = QSystemTrayIcon(tray_icon(), self)
        self.tray.setToolTip(APP)
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.build_menu)
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.tray_clicked)
        self.tray.show()

        self.manager.changed.connect(self.refresh_tray)
        self.settings.changed.connect(self.refresh_tray)
        self.manager.needs_attention.connect(self.show_window)
        self.manager.job_finished.connect(self.notify_finished)
        QGuiApplication.clipboard().dataChanged.connect(self.check_clipboard)
        app.aboutToQuit.connect(self.quitting)

        register_url_scheme()
        if not find_tool("yt-dlp"):
            self.notify("yt-dlp wasn't found", "Reinstall Clipload, or put yt-dlp.exe next to Clipload.exe.", timeout=0)
        if not background:
            self.show_window()

    def notify(self, title, subtitle, buttons=(), timeout=8):
        self.toast.show_message(title, subtitle, buttons, timeout)

    # Window

    def show_window(self):
        w = self.window
        w.showNormal() if w.isMinimized() else w.show()
        w.raise_()
        w.activateWindow()

    def window_closed(self):
        if not self.settings._get("trayHintShown", False, bool):
            self.settings.s.setValue("trayHintShown", True)
            self.notify("Clipload is still running", "It keeps watching for links in the tray. Right-click the tray icon to quit.")

    def tray_clicked(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            self.show_window()

    def quitting(self):
        for j in self.manager.jobs:
            if j.process:
                j.cancelled = True
                kill_process(j.process)

    # Clipboard

    def check_clipboard(self):
        if self.settings.clip_mode == "off":
            return
        # Ignore copies made inside Clipload's own windows (e.g. pasting into the link field).
        if QApplication.activeWindow() is not None:
            return
        data = QGuiApplication.clipboard().mimeData()
        # Never look at passwords or other secrets copied from password managers.
        if data is None or any(s in fmt for fmt in data.formats() for s in SECRET_FORMATS):
            return
        url = link_from(data.text())
        if not url or not (self.settings.any_link or is_video_link(url)) or url == self.last_offered:
            return
        self.last_offered = url
        if self.settings.clip_mode == "auto":
            self.manager.add(Request(url))
        else:
            self.offer(Request(url))

    def offer(self, req):
        question = f"Download “{req.title}”?" if req.title else "Download this video?"
        self.notify(question, req.url, [
            ("Download", lambda: self.manager.add(req)),
            ("Audio only", lambda: self.manager.add(req, audio=True)),
        ], timeout=10)

    # clipload:// links (sent by the Stream Grabber userscript)
    #
    #   clipload://download?url=<media or page>&referer=<page>&title=<title>&audio=1&token=<secret>

    def handle_url(self, s):
        try:
            u = urlparse(s)
        except ValueError:
            return
        if u.scheme != "clipload":
            return
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        url = link_from(q.get("url", ""))
        if not url:
            self.notify("Clipload got an invalid link", s)
            return
        title = (q.get("title") or "").strip() or None
        req = Request(url, referer=link_from(q.get("referer", "")), title=title)
        audio = q.get("audio") == "1"
        if q.get("token") == self.settings.token:
            self.manager.add(req, audio=audio)
            if self.manager.jobs and self.manager.jobs[0].state != PROBING:
                self.notify("Added audio download" if audio else "Added download", req.title or url, timeout=3)
        else:
            self.offer(req)

    # Notifications

    def notify_finished(self, job):
        # The window already shows it.
        if self.window.isActiveWindow():
            return
        if job.state == DONE and job.file:
            f = job.file
            self.notify("Downloaded", job.title, [("Show in Folder", lambda: reveal(f)), ("Open", lambda: open_file(f))])
        elif job.state == FAILED:
            self.notify("Couldn't download", job.error, [
                ("Retry", lambda: self.manager.retry(job)),
                ("Open Clipload", self.show_window),
            ], timeout=12)

    # Tray

    def refresh_tray(self):
        running = self.manager.running
        queued = self.manager.count(QUEUED)
        if running:
            avg = sum(j.percent for j in running) / len(running)
            self.tray.setIcon(tray_icon(avg))
            self.tray.setToolTip(f"Clipload — {int(avg)}%" + (f", {queued} queued" if queued else ""))
        else:
            self.tray.setIcon(tray_icon(paused=self.settings.clip_mode == "off"))
            self.tray.setToolTip(APP)

    def build_menu(self):
        m = self.menu
        m.clear()
        m.addAction("Open Clipload", self.show_window)
        m.addSeparator()
        active = [j for j in self.manager.jobs if not j.finished]
        labels = {RUNNING: lambda j: f"{int(j.percent)}%", QUEUED: lambda j: "queued",
                  PROBING: lambda j: "checking…", CHOOSING: lambda j: "pick a quality"}
        for job in active[:8]:
            title = job.title if len(job.title) <= 50 else job.title[:48] + "…"
            m.addAction(f"{title} — {labels[job.state](job)}", self.show_window)
        if active:
            m.addAction("Cancel All", self.manager.cancel_all)
            m.addSeparator()
        m.addAction("Download Link from Clipboard", self.download_clipboard)
        m.addSeparator()

        clip = m.addMenu("When I Copy a Link")
        group = QActionGroup(clip)
        for key, label in CLIP_MODES:
            a = clip.addAction(label, lambda k=key: setattr(self.settings, "clip_mode", k))
            a.setCheckable(True)
            a.setChecked(self.settings.clip_mode == key)
            group.addAction(a)
        qual = m.addMenu("Default Quality")
        group = QActionGroup(qual)
        for key, label, *_ in QUALITIES:
            a = qual.addAction(label, lambda k=key: setattr(self.settings, "quality", k))
            a.setCheckable(True)
            a.setChecked(self.settings.quality == key)
            group.addAction(a)
        m.addAction("Settings…", lambda: (self.show_window(), self.window.show_settings()))
        m.addSeparator()
        m.addAction("Quit Clipload", self.app.quit)

    def download_clipboard(self):
        url = link_from(QGuiApplication.clipboard().text())
        if url:
            self.manager.add(Request(url))
        else:
            self.notify("No link on the clipboard", "Copy a video link first.")


def main():
    args = sys.argv[1:]
    link = next((a for a in args if a.lower().startswith("clipload:")), None)
    background = "--background" in args

    app = QApplication(sys.argv)
    app.setApplicationName(APP)
    app.setApplicationVersion(VERSION)
    app.setQuitOnLastWindowClosed(False)
    app.setWindowIcon(app_icon())
    if IS_WIN:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Clipload.Clipload")

    # One copy at a time: a second launch (e.g. a clipload:// link) hands its link to the first.
    name = f"clipload-{getpass.getuser()}"
    sock = QLocalSocket()
    sock.connectToServer(name)
    if sock.waitForConnected(500):
        sock.write(((link or ("BACKGROUND" if background else "SHOW")) + "\n").encode())
        sock.waitForBytesWritten(1000)
        sock.disconnectFromServer()
        return 0

    QLocalServer.removeServer(name)
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.UserAccessOption)
    server.listen(name)
    clipload = Clipload(app, background or link is not None)

    def incoming():
        conn = server.nextPendingConnection()

        def read():
            while conn.canReadLine():
                msg = conn.readLine().data().decode("utf-8", "replace").strip()
                if msg == "SHOW":
                    clipload.show_window()
                elif msg.lower().startswith("clipload:"):
                    clipload.handle_url(msg)

        conn.readyRead.connect(read)
        conn.disconnected.connect(conn.deleteLater)

    server.newConnection.connect(incoming)
    if link:
        QTimer.singleShot(0, lambda: clipload.handle_url(link))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
