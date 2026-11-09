"""Writes clipload.ico (16–256 px) from the icon drawn in clipload.py: python make_icon.py"""

import struct
import sys

from PySide6.QtCore import QBuffer, QIODevice
from PySide6.QtGui import QGuiApplication

from clipload import draw_app_icon

app = QGuiApplication(sys.argv)
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
images = []
for s in sizes:
    buf = QBuffer()
    buf.open(QIODevice.WriteOnly)
    draw_app_icon(s).save(buf, "PNG")
    images.append(bytes(buf.data()))

# ICO = header, one directory entry per size, then the PNG data.
data = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, png in zip(sizes, images):
    data += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
data += b"".join(images)
with open("clipload.ico", "wb") as f:
    f.write(data)
print("wrote clipload.ico")
