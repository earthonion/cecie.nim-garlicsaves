import asyncdispatch
import posix
import logging
import strutils

import "./config"
import "./syscalls"

import "orbis/private/VideoOut"
import "orbis/private/_types/video"
import "orbis/private/Sysmodule"
import "orbis/private/_types/sysmodule"
import "orbis/private/libkernel"
import "freetype"

const
  FRAME_WIDTH = 1920
  FRAME_HEIGHT = 1080
  FRAME_DEPTH = 4
  FRAME_BUFFER_SIZE = FRAME_WIDTH * FRAME_HEIGHT * FRAME_DEPTH
  NUM_FRAME_BUFFERS = 2
  VIDEO_MEM_SIZE = 0xC000000'u  # 192MB
  VIDEO_MEM_ALIGN = 0x200000'u  # 2MB alignment
  FONT_PATH = "/app0/assets/fonts/NotoSans.ttf"
  FONT_SIZE = 28
  MAX_LOG_LINES* = 20

type
  Color* = object
    r*, g*, b*: uint8

  DisplayState* = object
    jobsCompleted*: int
    jobsFailed*: int
    currentJob*: string
    maxKeyset*: int
    recentLogs*: seq[string]
    workerStatus*: string

var
  videoHandle: cint
  flipQueue: OrbisKernelEqueue
  directMemOff: Off
  videoMem: pointer
  videoMemSP: uint
  frameBuffers: array[NUM_FRAME_BUFFERS, pointer]
  activeBuffer: int
  frameID: int64
  ftLib: FT_Library
  font: FT_Face
  displayReady*: bool = false
  displayState*: DisplayState

proc allocDisplayMem(size: int): pointer =
  result = cast[pointer](videoMemSP)
  videoMemSP += uint(size)

proc drawPixel(x, y: int, color: Color) =
  if x < 0 or y < 0 or x >= FRAME_WIDTH or y >= FRAME_HEIGHT:
    return
  let pixel = y * FRAME_WIDTH + x
  let encoded = 0x80000000'u32 or (uint32(color.r) shl 16) or (uint32(color.g) shl 8) or uint32(color.b)
  cast[ptr UncheckedArray[uint32]](frameBuffers[activeBuffer])[pixel] = encoded

proc drawRect(x, y, w, h: int, color: Color) =
  for yy in y ..< y + h:
    if yy < 0 or yy >= FRAME_HEIGHT: continue
    for xx in x ..< x + w:
      if xx < 0 or xx >= FRAME_WIDTH: continue
      let pixel = yy * FRAME_WIDTH + xx
      let encoded = 0x80000000'u32 or (uint32(color.r) shl 16) or (uint32(color.g) shl 8) or uint32(color.b)
      cast[ptr UncheckedArray[uint32]](frameBuffers[activeBuffer])[pixel] = encoded

proc clearScreen(color: Color) =
  let encoded = 0x80000000'u32 or (uint32(color.r) shl 16) or (uint32(color.g) shl 8) or uint32(color.b)
  let buf = cast[ptr UncheckedArray[uint32]](frameBuffers[activeBuffer])
  for i in 0 ..< FRAME_WIDTH * FRAME_HEIGHT:
    buf[i] = encoded

proc drawText(text: string, face: FT_Face, startX, startY: int, color: Color) =
  let slot = face.glyph
  var xOffset = 0
  var yOffset = 0

  for ch in text:
    if ch == '\n':
      xOffset = 0
      yOffset += int(FONT_SIZE) + 8
      continue

    let glyphIndex = FT_Get_Char_Index(face, culong(ord(ch)))
    if FT_Load_Glyph(face, glyphIndex, FT_LOAD_DEFAULT) != 0:
      continue
    if FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0:
      continue

    let bmp = slot.bitmap
    for yPos in 0 ..< int(bmp.rows):
      for xPos in 0 ..< int(bmp.width):
        let pixel = bmp.buffer[yPos * int(bmp.pitch) + xPos]
        if pixel == 0: continue

        let x = startX + xPos + xOffset + int(slot.bitmap_left)
        let y = startY + yPos + yOffset - int(slot.bitmap_top)

        let r = uint8((uint16(pixel) * uint16(color.r)) div 255)
        let g = uint8((uint16(pixel) * uint16(color.g)) div 255)
        let b = uint8((uint16(pixel) * uint16(color.b)) div 255)

        drawPixel(x, y, Color(r: r, g: g, b: b))

    xOffset += int(slot.advance.x shr 6)

proc initDisplay*(): bool =
  # Open video output
  videoHandle = sceVideoOutOpen(ORBIS_VIDEO_USER_MAIN, ORBIS_VIDEO_OUT_BUS_MAIN, 0, nil)
  if videoHandle < 0:
    log(lvlError, "Failed to open video out: ", $videoHandle)
    return false

  # Load FreeType module
  let sysRc = sceSysmoduleLoadModule(uint16(ORBIS_SYSMODULE_FREETYPE_OL))
  if sysRc < 0:
    log(lvlError, "Failed to load FreeType module: ", $sysRc)
    return false

  if FT_Init_FreeType(ftLib.addr) != 0:
    log(lvlError, "Failed to init FreeType")
    return false

  # Init flip queue
  var rc = sceKernelCreateEqueue(flipQueue.addr, "display flip queue")
  if rc < 0:
    log(lvlError, "Failed to create flip equeue: ", $rc)
    return false

  rc = sceVideoOutAddFlipEvent(flipQueue, videoHandle, nil)
  if rc < 0:
    log(lvlError, "Failed to add flip event: ", $rc)
    return false

  # Allocate direct memory for framebuffers
  let alignedSize = csize_t((VIDEO_MEM_SIZE + VIDEO_MEM_ALIGN - 1) div VIDEO_MEM_ALIGN * VIDEO_MEM_ALIGN)

  rc = sceKernelAllocateDirectMemory(Off(0), Off(sceKernelGetDirectMemorySize()),
    alignedSize, csize_t(VIDEO_MEM_ALIGN), 3, directMemOff.addr)
  if rc < 0:
    log(lvlError, "Failed to allocate direct memory: ", $rc)
    return false

  # Map to virtual address space (0x33 = CPU_RW | GPU_RW)
  rc = sceKernelMapDirectMemory(videoMem.addr, alignedSize, 0x33, 0, directMemOff, csize_t(VIDEO_MEM_ALIGN))
  if rc < 0:
    log(lvlError, "Failed to map direct memory: ", $rc)
    return false

  videoMemSP = cast[uint](videoMem)

  # Allocate frame buffers from video memory
  for i in 0 ..< NUM_FRAME_BUFFERS:
    frameBuffers[i] = allocDisplayMem(FRAME_BUFFER_SIZE)

  # Configure buffer attributes
  var attr: OrbisVideoOutBufferAttribute
  sceVideoOutSetBufferAttribute(cast[pointer](attr.addr), cuint(0x80000000'u32), cuint(1), cuint(0), cuint(FRAME_WIDTH), cuint(FRAME_HEIGHT), cuint(FRAME_WIDTH))

  # Register buffers
  var bufPtrs: array[NUM_FRAME_BUFFERS, pointer]
  for i in 0 ..< NUM_FRAME_BUFFERS:
    bufPtrs[i] = frameBuffers[i]

  rc = sceVideoOutRegisterBuffers(videoHandle, 0, bufPtrs[0].addr, NUM_FRAME_BUFFERS.cint, attr.addr)
  if rc < 0:
    log(lvlError, "Failed to register buffers: ", $rc)
    return false

  discard sceVideoOutSetFlipRate(videoHandle, 0)

  # Load font
  if FT_New_Face(ftLib, FONT_PATH, 0, font.addr) != 0:
    log(lvlError, "Failed to load font: ", FONT_PATH)
    return false

  if FT_Set_Pixel_Sizes(font, 0, cuint(FONT_SIZE)) != 0:
    log(lvlError, "Failed to set font size")
    return false

  displayState.workerStatus = "idle"
  displayReady = true
  log(lvlInfo, "Display initialized")
  return true

proc submitFlip() =
  discard sceVideoOutSubmitFlip(videoHandle, activeBuffer.cint, cuint(ORBIS_VIDEO_OUT_FLIP_VSYNC), frameID)

proc frameWait() =
  var evt: array[32, byte]  # kevent struct is 32 bytes
  var count: cint
  while true:
    var flipStatus: OrbisVideoOutFlipStatus
    discard sceVideoOutGetFlipStatus(videoHandle, flipStatus.addr)
    if flipStatus.flipArg == frameID:
      break
    if sceKernelWaitEqueue(flipQueue, cast[ptr OrbisKernelEvent](evt.addr), 1, count.addr, nil) != 0:
      break

proc frameBufferSwap() =
  activeBuffer = (activeBuffer + 1) mod NUM_FRAME_BUFFERS

proc addDisplayLog*(msg: string) =
  displayState.recentLogs.add(msg)
  if displayState.recentLogs.len > MAX_LOG_LINES:
    displayState.recentLogs.delete(0)
  # Append to persistent log file
  let fd = sys_open(LOG_FILE.cstring, O_CREAT or O_WRONLY or O_APPEND, 0o777)
  if fd != -1:
    let line = msg & "\n"
    discard sys_write(fd, line[0].unsafeAddr, line.len)
    discard sys_close(fd)

proc loadPreviousLogs*() =
  ## Read previous logs from LOG_FILE into displayState.recentLogs on startup.
  let fd = sys_open(LOG_FILE.cstring, O_RDONLY, 0)
  if fd == -1:
    return
  let size = int(sys_lseek(fd, Off(0), SEEK_END))
  if size <= 0:
    discard sys_close(fd)
    return
  discard sys_lseek(fd, Off(0), SEEK_SET)
  var buf = newString(size)
  discard sys_read(fd, buf[0].addr, size)
  discard sys_close(fd)
  # Take last MAX_LOG_LINES lines
  var lines: seq[string] = @[]
  for line in buf.splitLines():
    if line.len > 0:
      lines.add(line)
  let start = max(0, lines.len - MAX_LOG_LINES)
  displayState.recentLogs = lines[start ..< lines.len]

proc renderFrame() =
  let bg = Color(r: 20, g: 22, b: 30)
  let white = Color(r: 220, g: 220, b: 230)
  let cyan = Color(r: 80, g: 200, b: 220)
  let green = Color(r: 80, g: 200, b: 120)
  let red = Color(r: 220, g: 80, b: 80)
  let dimWhite = Color(r: 150, g: 150, b: 160)

  clearScreen(bg)

  # Title
  drawText("CECIE Worker", font, 60, 60, cyan)

  # Status line
  let statusColor = if displayState.workerStatus == "idle": dimWhite else: green
  drawText("Status: " & displayState.workerStatus, font, 60, 110, statusColor)

  # Keyset
  drawText("Max Keyset: " & $displayState.maxKeyset, font, 60, 150, white)

  # Job stats
  let statsText = "Jobs: " & $displayState.jobsCompleted & " completed, " & $displayState.jobsFailed & " failed"
  drawText(statsText, font, 60, 190, white)

  # Separator
  drawRect(60, 230, FRAME_WIDTH - 120, 2, dimWhite)

  # Recent activity header
  drawText("Recent Activity", font, 60, 255, cyan)

  # Log lines
  var y = 295
  for i, line in displayState.recentLogs:
    let logColor = if line.len >= 7 and line[0..6] == "[ERROR]": red
                   elif line.len >= 9 and line[0..8] == "[WARNING]": Color(r: 220, g: 180, b: 60)
                   else: dimWhite
    drawText(line, font, 60, y, logColor)
    y += int(FONT_SIZE) + 6
    if y > FRAME_HEIGHT - 40:
      break

proc displayLoop*() {.async.} =
  if not displayReady:
    return

  log(lvlInfo, "Display loop started")
  while true:
    renderFrame()
    submitFlip()
    frameWait()
    frameBufferSwap()
    frameID += 1
    # ~30fps - yield to async event loop
    await sleepAsync(33)
