import asyncdispatch
import strutils
import os
import posix
import json
import logging

import "./httpclient"
import "./config"
import "./savedata"
import "./syscalls"
import "./commands/utils"

const WORK_DIR = "/data/cecie/work"

type WorkerError* = object of CatchableError
const ZIP_LOCAL_HEADER_SIG = 0x04034b50'u32
const ZIP_CENTRAL_DIR_SIG = 0x02014b50'u32
const ZIP_END_CENTRAL_SIG = 0x06054b50'u32

# ---- CRC-32 ----

proc makeCrc32Table(): array[256, uint32] =
  for i in 0'u32 ..< 256:
    var c = i
    for j in 0 ..< 8:
      if (c and 1) != 0:
        c = 0xEDB88320'u32 xor (c shr 1)
      else:
        c = c shr 1
    result[i] = c

const crc32Table = makeCrc32Table()

proc crc32Fd(fd: cint, size: int): uint32 =
  result = 0xFFFFFFFF'u32
  var chunk: array[32768, byte]
  var remaining = size
  while remaining > 0:
    let toRead = min(remaining, chunk.len)
    let n = sys_read(fd, chunk[0].addr, toRead)
    if n <= 0:
      break
    let p = cast[ptr UncheckedArray[uint8]](chunk[0].addr)
    for i in 0 ..< int(n):
      result = crc32Table[(result xor p[i].uint32) and 0xFF] xor (result shr 8)
    remaining -= int(n)
  result = result xor 0xFFFFFFFF'u32

# ---- Directory helpers ----

proc ensureDir(path: string) =
  discard mkdir(path.cstring, 0o777)

proc ensureDirRec(path: string) =
  ## Recursively create directories like mkdir -p
  var parts: seq[string] = @[]
  var cur = path
  while cur.len > 1:
    parts.add(cur)
    cur = parentDir(cur)
  # Create from root down
  for i in countdown(parts.high, 0):
    discard mkdir(parts[i].cstring, 0o777)

proc removeRecursive(path: string) =
  try:
    removeDir(path)
  except OSError:
    discard

# ---- ZIP extract ----

proc extractZip*(zipPath: string, destDir: string): bool =
  ## Extract a ZIP_STORED archive from file descriptor.
  let fd = sys_open(zipPath.cstring, O_RDONLY, 0)
  if fd == -1:
    return false

  var extracted = 0
  var headerBuf: array[30, byte]
  var chunk: array[32768, byte]

  while true:
    let hdrRead = sys_read(fd, headerBuf[0].addr, 30)
    if hdrRead < 30:
      break

    let sig = cast[ptr uint32](headerBuf[0].addr)[]
    if sig != ZIP_LOCAL_HEADER_SIG:
      break

    let compressedSize = int(cast[ptr uint32](headerBuf[18].addr)[])
    let filenameLen = int(cast[ptr uint16](headerBuf[26].addr)[])
    let extraLen = int(cast[ptr uint16](headerBuf[28].addr)[])

    var filename = newString(filenameLen)
    if filenameLen > 0:
      discard sys_read(fd, filename[0].addr, filenameLen)

    if extraLen > 0:
      discard sys_lseek(fd, Off(extraLen), SEEK_CUR)

    let destPath = destDir & "/" & filename

    if filename.endsWith("/"):
      ensureDirRec(destPath)
      if compressedSize > 0:
        discard sys_lseek(fd, Off(compressedSize), SEEK_CUR)
    else:
      let parent = parentDir(destPath)
      if parent.len > 0:
        ensureDirRec(parent)

      let outFd = sys_open(destPath.cstring, O_CREAT or O_WRONLY or O_TRUNC, 0o777)
      if outFd != -1:
        var remaining = compressedSize
        while remaining > 0:
          let toRead = min(remaining, chunk.len)
          let n = sys_read(fd, chunk[0].addr, toRead)
          if n <= 0:
            break
          discard sys_write(outFd, chunk[0].addr, int(n))
          remaining -= int(n)
        discard sys_close(outFd)
        extracted += 1
      else:
        if compressedSize > 0:
          discard sys_lseek(fd, Off(compressedSize), SEEK_CUR)

  discard sys_close(fd)
  return extracted > 0

# ---- ZIP create ----

proc writeLE16(buf: var string, val: uint16) =
  buf.add(chr(val and 0xFF))
  buf.add(chr((val shr 8) and 0xFF))

proc writeLE32(buf: var string, val: uint32) =
  buf.add(chr(val and 0xFF))
  buf.add(chr((val shr 8) and 0xFF))
  buf.add(chr((val shr 16) and 0xFF))
  buf.add(chr((val shr 24) and 0xFF))

proc createZipFromDir*(srcDir: string, zipPath: string): bool =
  ## Create a ZIP_STORED archive from all files in srcDir.
  ## Each file is read twice (CRC pass then copy pass).
  type FileEntry = tuple[arcname: string, offset: int, size: int, crc: uint32]
  var entries: seq[FileEntry] = @[]

  let outFd = sys_open(zipPath.cstring, O_CREAT or O_WRONLY or O_TRUNC, 0o777)
  if outFd == -1:
    return false

  var outputPos = 0
  var chunk: array[32768, byte]

  for path in walkDirRec(srcDir):
      let arcname = relativePath(path, srcDir)

      let inFd = sys_open(path.cstring, O_RDONLY, 0)
      if inFd == -1:
        continue

      let fsize = int(sys_lseek(inFd, Off(0), SEEK_END))
      if fsize <= 0:
        discard sys_close(inFd)
        continue
      discard sys_lseek(inFd, Off(0), SEEK_SET)

      let fileCrc = crc32Fd(inFd, fsize)
      discard sys_lseek(inFd, Off(0), SEEK_SET)

      let offset = outputPos

      var hdr = ""
      writeLE32(hdr, ZIP_LOCAL_HEADER_SIG)
      writeLE16(hdr, 20'u16) # version needed
      writeLE16(hdr, 0'u16)  # flags
      writeLE16(hdr, 0'u16)  # compression (stored)
      writeLE16(hdr, 0'u16)  # mod time
      writeLE16(hdr, 0'u16)  # mod date
      writeLE32(hdr, fileCrc)
      writeLE32(hdr, fsize.uint32)  # compressed
      writeLE32(hdr, fsize.uint32)  # uncompressed
      writeLE16(hdr, arcname.len.uint16)
      writeLE16(hdr, 0'u16)  # extra len
      hdr.add(arcname)

      discard sys_write(outFd, hdr[0].addr, hdr.len)
      outputPos += hdr.len

      var remaining = fsize
      while remaining > 0:
        let toRead = min(remaining, chunk.len)
        let n = sys_read(inFd, chunk[0].addr, toRead)
        if n <= 0:
          break
        discard sys_write(outFd, chunk[0].addr, int(n))
        outputPos += int(n)
        remaining -= int(n)

      discard sys_close(inFd)
      entries.add((arcname, offset, fsize, fileCrc))

  if entries.len == 0:
    discard sys_close(outFd)
    return false

  # Central directory
  let cdOffset = outputPos
  var cd = ""
  for e in entries:
    writeLE32(cd, ZIP_CENTRAL_DIR_SIG)
    writeLE16(cd, 20'u16) # version made by
    writeLE16(cd, 20'u16) # version needed
    writeLE16(cd, 0'u16)  # flags
    writeLE16(cd, 0'u16)  # compression
    writeLE16(cd, 0'u16)  # mod time
    writeLE16(cd, 0'u16)  # mod date
    writeLE32(cd, e.crc)
    writeLE32(cd, e.size.uint32)
    writeLE32(cd, e.size.uint32)
    writeLE16(cd, e.arcname.len.uint16)
    writeLE16(cd, 0'u16)  # extra len
    writeLE16(cd, 0'u16)  # comment len
    writeLE16(cd, 0'u16)  # disk number start
    writeLE16(cd, 0'u16)  # internal attrs
    writeLE32(cd, 0'u32)  # external attrs
    writeLE32(cd, e.offset.uint32) # local header offset
    cd.add(e.arcname)

  let cdSize = cd.len

  # End of central directory
  writeLE32(cd, ZIP_END_CENTRAL_SIG)
  writeLE16(cd, 0'u16) # disk number
  writeLE16(cd, 0'u16) # start disk
  writeLE16(cd, entries.len.uint16)
  writeLE16(cd, entries.len.uint16)
  writeLE32(cd, cdSize.uint32)
  writeLE32(cd, cdOffset.uint32)
  writeLE16(cd, 0'u16) # comment len

  discard sys_write(outFd, cd[0].addr, cd.len)
  discard sys_close(outFd)
  return true

# ---- HTTP helpers ----

proc authHeaders(): seq[(string, string)] =
  @[("X-Worker-Key", WORKER_KEY)]

proc workerLog(jobId: string, level: string, msg: string) {.async.} =
  let body = $(%*{"level": level, "msg": msg})
  discard await httpPost(SERVER_HOST, SERVER_HTTP_PORT,
    "/api/worker/jobs/" & jobId & "/log", body, "application/json",
    authHeaders())

proc workerSetStatus(jobId: string, status: string, error: string = "") {.async.} =
  var obj = %*{"status": status}
  if error.len > 0:
    obj["error"] = %error
  discard await httpPost(SERVER_HOST, SERVER_HTTP_PORT,
    "/api/worker/jobs/" & jobId & "/status", $obj, "application/json",
    authHeaders())

proc uploadResultFile(jobId: string, srcPath: string): Future[bool] {.async.} =
  let status = await httpUploadFile(SERVER_HOST, SERVER_HTTP_PORT,
    "/api/worker/jobs/" & jobId & "/result", srcPath, authHeaders())
  return status == 200

proc downloadAndExtract(jobId: string, workDir: string, filesDir: string) {.async.} =
  ## Download job files and extract zip. Raises WorkerError on failure.
  let zipPath = workDir & "/files.zip"
  let dlStatus = await httpDownloadToFile(SERVER_HOST, SERVER_HTTP_PORT,
    "/api/worker/jobs/" & jobId & "/files", zipPath, authHeaders())
  if dlStatus != 200:
    await workerLog(jobId, "ERROR", "Failed to download files (HTTP " & $dlStatus & ")")
    raise newException(WorkerError, "Failed to download job files")

  # Check file size without loading into memory
  let checkFd = sys_open(zipPath.cstring, O_RDONLY, 0)
  var dlSize: Off = 0
  if checkFd != -1:
    dlSize = sys_lseek(checkFd, Off(0), SEEK_END)
    discard sys_close(checkFd)
  await workerLog(jobId, "INFO", "Files downloaded (" & $dlSize & " bytes), extracting...")

  if dlSize <= 0:
    await workerLog(jobId, "ERROR", "Downloaded file is empty or unreadable")
    raise newException(WorkerError, "Downloaded file is empty")

  if not extractZip(zipPath, filesDir):
    await workerLog(jobId, "ERROR", "Failed to extract zip (file was " & $dlSize & " bytes)")
    raise newException(WorkerError, "Failed to extract zip")

  # Log what we extracted
  var fileCount = 0
  for (kind, path) in walkDir(filesDir):
    if kind == pcFile:
      fileCount += 1
      await workerLog(jobId, "INFO", "  extracted: " & extractFilename(path))

  if fileCount == 0:
    await workerLog(jobId, "ERROR", "Zip was empty or extraction produced no files")
    raise newException(WorkerError, "No files extracted")

proc zipAndUploadResults(jobId: string, resultDir: string, workDir: string) {.async.} =
  ## Zip the result directory and upload it. Raises WorkerError on failure.
  let resultZip = workDir & "/result.zip"
  if not createZipFromDir(resultDir, resultZip):
    await workerLog(jobId, "ERROR", "No result files to zip")
    raise newException(WorkerError, "No result files")

  await workerLog(jobId, "INFO", "Uploading results...")
  if not await uploadResultFile(jobId, resultZip):
    await workerLog(jobId, "ERROR", "Failed to upload result")
    raise newException(WorkerError, "Failed to upload result")

# ---- Job processors ----

proc processResign(jobId: string, params: JsonNode) {.async.} =
  await workerLog(jobId, "INFO", "Starting resign...")
  let accountIdStr = params["account_id"].getStr()
  var accountId: uint64
  try:
    accountId = parseHexInt(accountIdStr).uint64
  except ValueError:
    await workerLog(jobId, "ERROR", "Invalid account_id: " & accountIdStr)
    raise newException(WorkerError, "Invalid account_id")

  let workDir = WORK_DIR & "/" & jobId
  ensureDir(workDir)
  let filesDir = workDir & "/files"
  ensureDir(filesDir)
  let resultDir = workDir & "/result"
  ensureDir(resultDir)

  await downloadAndExtract(jobId, workDir, filesDir)

  await workerLog(jobId, "INFO", "Resigning saves to account " & accountIdStr)

  let saveDir = SAVE_DIRECTORY
  var processed = 0

  for (kind, path) in walkDir(filesDir):
    if kind == pcFile and not path.endsWith(".bin"):
      let baseName = extractFilename(path)
      let binPath = path & ".bin"
      if not fileExists(binPath):
        await workerLog(jobId, "WARNING", "No .bin companion for " & baseName & ", skipping")
        continue

      let destSave = joinPath(saveDir, baseName)
      let destBin = joinPath(saveDir, baseName & ".bin")
      copyFile(path, destSave)
      copyFile(binPath, destBin)

      await workerLog(jobId, "INFO", "Resigning " & baseName & "...")

      setupCredentials()
      let mntFolder = "/data/cecie_mnt_" & jobId[0..7]
      discard rmdir(mntFolder.cstring)
      discard mkdir(mntFolder.cstring, 0o777)

      let (errPath, handle) = mountSave(saveDir, baseName, mntFolder)
      if errPath != 0:
        await workerLog(jobId, "ERROR", "Mount failed for " & baseName & ": 0x" & errPath.toHex(8))
        discard rmdir(mntFolder.cstring)
        removeFile(destSave)
        removeFile(destBin)
        continue

      discard setuid(0)
      let sfoPath = joinPath(mntFolder, "sce_sys/param.sfo")
      let sfoFd = open(sfoPath.cstring, O_RDWR, 0o777)
      if sfoFd != -1:
        let writeResult = sys_pwrite(sfoFd, accountId.addr, 8, Off(0x15C))
        discard close(sfoFd)
        if writeResult == 8:
          await workerLog(jobId, "INFO", "Resigned " & baseName & " OK")
          processed += 1
        else:
          await workerLog(jobId, "ERROR", "pwrite failed for " & baseName)
      else:
        await workerLog(jobId, "ERROR", "Could not open param.sfo for " & baseName)

      discard umountSave(mntFolder, handle, false)
      discard rmdir(mntFolder.cstring)

      # Copy resigned files to result dir
      copyFile(destSave, joinPath(resultDir, baseName))
      copyFile(destBin, joinPath(resultDir, baseName & ".bin"))

      removeFile(destSave)
      removeFile(destBin)

  if processed == 0:
    await workerLog(jobId, "ERROR", "No saves were successfully resigned")
    raise newException(WorkerError, "No saves processed")

  await zipAndUploadResults(jobId, resultDir, workDir)
  removeRecursive(workDir)

proc processDecrypt(jobId: string, params: JsonNode) {.async.} =
  await workerLog(jobId, "INFO", "Starting decrypt...")

  let workDir = WORK_DIR & "/" & jobId
  ensureDir(workDir)
  let filesDir = workDir & "/files"
  ensureDir(filesDir)
  let resultDir = workDir & "/result"
  ensureDir(resultDir)

  await downloadAndExtract(jobId, workDir, filesDir)

  let includeSceSys = params.getOrDefault("include_sce_sys").getBool(false)
  let saveDir = SAVE_DIRECTORY
  var processed = 0

  for (kind, path) in walkDir(filesDir):
    if kind == pcFile and not path.endsWith(".bin"):
      let baseName = extractFilename(path)
      let binPath = path & ".bin"
      if not fileExists(binPath):
        continue

      let destSave = joinPath(saveDir, baseName)
      let destBin = joinPath(saveDir, baseName & ".bin")
      copyFile(path, destSave)
      copyFile(binPath, destBin)

      await workerLog(jobId, "INFO", "Decrypting " & baseName & "...")

      setupCredentials()
      let mntFolder = "/data/cecie_mnt_" & jobId[0..7]
      discard rmdir(mntFolder.cstring)
      discard mkdir(mntFolder.cstring, 0o777)

      let (errPath, handle) = mountSave(saveDir, baseName, mntFolder)
      if errPath != 0:
        await workerLog(jobId, "ERROR", "Mount failed for " & baseName & ": 0x" & errPath.toHex(8))
        discard rmdir(mntFolder.cstring)
        removeFile(destSave)
        removeFile(destBin)
        continue

      # Dump files from mounted save
      let outDir = resultDir & "/" & baseName
      ensureDir(outDir)

      discard setuid(0)
      for (fKind, relativePath) in getRequiredFiles(mntFolder, @[]):
        if fKind == pcDir:
          if includeSceSys or not relativePath.startsWith("sce_sys"):
            ensureDirRec(joinPath(outDir, relativePath))
        elif fKind == pcFile:
          if not includeSceSys and relativePath.startsWith("sce_sys"):
            continue
          let srcFile = joinPath(mntFolder, relativePath)
          let dstFile = joinPath(outDir, relativePath)
          # Ensure parent dir exists
          ensureDirRec(parentDir(dstFile))
          try:
            copyFile(srcFile, dstFile)
          except IOError:
            await workerLog(jobId, "WARNING", "Failed to copy " & relativePath)
          except OSError:
            await workerLog(jobId, "WARNING", "Failed to copy " & relativePath)

      discard umountSave(mntFolder, handle, false)
      discard rmdir(mntFolder.cstring)

      await workerLog(jobId, "INFO", "Decrypted " & baseName)
      processed += 1

      removeFile(destSave)
      removeFile(destBin)

  if processed == 0:
    await workerLog(jobId, "ERROR", "No saves were successfully decrypted")
    raise newException(WorkerError, "No saves processed")

  await zipAndUploadResults(jobId, resultDir, workDir)
  removeRecursive(workDir)

proc processEncrypt(jobId: string, params: JsonNode) {.async.} =
  await workerLog(jobId, "INFO", "Starting encrypt...")

  let savename = params["savename"].getStr()
  let saveblocks = params["saveblocks"].getInt().cint

  let workDir = WORK_DIR & "/" & jobId
  ensureDir(workDir)
  let filesDir = workDir & "/files"
  ensureDir(filesDir)
  let resultDir = workDir & "/result"
  ensureDir(resultDir)

  await downloadAndExtract(jobId, workDir, filesDir)

  await workerLog(jobId, "INFO", "Creating save " & savename & " (" & $saveblocks & " blocks)...")

  setupCredentials()
  await workerLog(jobId, "INFO", "Console max keyset: " & $getMaxKeySet())

  let saveDir = SAVE_DIRECTORY
  let createResult = createSave(saveDir, savename, saveblocks)
  if createResult != 0:
    await workerLog(jobId, "ERROR", "createSave failed: " & $createResult)
    raise newException(WorkerError, "createSave failed")

  let mntFolder = "/data/cecie_mnt_" & jobId[0..7]
  discard rmdir(mntFolder.cstring)
  discard mkdir(mntFolder.cstring, 0o777)

  let (errPath, handle) = mountSave(saveDir, savename, mntFolder)
  if errPath != 0:
    await workerLog(jobId, "ERROR", "Mount failed: 0x" & errPath.toHex(8))
    discard rmdir(mntFolder.cstring)
    raise newException(WorkerError, "Mount failed")

  # Copy uploaded files into mounted save
  for (kind, relativePath) in getRequiredFiles(filesDir, @[]):
    if relativePath.startsWith("sce_sys") or relativePath == "memory.dat":
      discard setuid(0)
    else:
      discard setuid(1)

    let targetPath = joinPath(mntFolder, relativePath)
    if kind == pcDir:
      discard mkdir(targetPath.cstring, 0o777)
    elif kind == pcFile:
      let fd = open(targetPath.cstring, O_CREAT or O_TRUNC, 0o777)
      discard close(fd)
      let sourcePath = joinPath(filesDir, relativePath)
      try:
        copyFile(sourcePath, targetPath)
      except IOError:
        await workerLog(jobId, "WARNING", "Failed to copy " & relativePath)
      except OSError:
        await workerLog(jobId, "WARNING", "Failed to copy " & relativePath)

  discard setuid(0)
  discard umountSave(mntFolder, handle, false)
  discard rmdir(mntFolder.cstring)

  await workerLog(jobId, "INFO", "Encrypted " & savename)

  # Copy save pair to result dir
  let savePath = joinPath(saveDir, savename)
  let binPath = joinPath(saveDir, savename & ".bin")
  copyFile(savePath, joinPath(resultDir, savename))
  copyFile(binPath, joinPath(resultDir, savename & ".bin"))

  removeFile(savePath)
  removeFile(binPath)

  await zipAndUploadResults(jobId, resultDir, workDir)
  removeRecursive(workDir)

proc processCreateSave(jobId: string, params: JsonNode) {.async.} =
  await processEncrypt(jobId, params)

proc processReregion(jobId: string, params: JsonNode) {.async.} =
  await workerLog(jobId, "INFO", "Starting re-region...")

  let accountIdStr = params["account_id"].getStr()
  var accountId: uint64
  try:
    accountId = parseHexInt(accountIdStr).uint64
  except ValueError:
    await workerLog(jobId, "ERROR", "Invalid account_id")
    raise newException(WorkerError, "Invalid account_id")

  let workDir = WORK_DIR & "/" & jobId
  ensureDir(workDir)
  let filesDir = workDir & "/files"
  ensureDir(filesDir)
  let resultDir = workDir & "/result"
  ensureDir(resultDir)

  await downloadAndExtract(jobId, workDir, filesDir)

  let savesDir = filesDir & "/saves"
  let sampleDir = filesDir & "/sample"

  # Mount sample save to get keystone
  setupCredentials()

  var keystoneData: array[0x400, byte]
  var hasKeystone = false
  let saveDir = SAVE_DIRECTORY

  for (kind, path) in walkDir(sampleDir):
    if kind == pcFile and not path.endsWith(".bin"):
      let baseName = extractFilename(path)
      let binPath = path & ".bin"
      if not fileExists(binPath):
        continue

      let destSave = joinPath(saveDir, baseName)
      let destBin = joinPath(saveDir, baseName & ".bin")
      copyFile(path, destSave)
      copyFile(binPath, destBin)

      let mntFolder = "/data/cecie_mnt_sample"
      discard rmdir(mntFolder.cstring)
      discard mkdir(mntFolder.cstring, 0o777)

      let (errPath, handle) = mountSave(saveDir, baseName, mntFolder)
      if errPath == 0:
        let keystonePath = joinPath(mntFolder, "sce_sys/keystone")
        let ksFd = open(keystonePath.cstring, O_RDONLY, 0)
        if ksFd != -1:
          discard read(ksFd, keystoneData.addr, 0x400)
          discard close(ksFd)
          hasKeystone = true
          await workerLog(jobId, "INFO", "Obtained keystone from sample " & baseName)
        discard umountSave(mntFolder, handle, false)
      discard rmdir(mntFolder.cstring)
      removeFile(destSave)
      removeFile(destBin)
      break

  if not hasKeystone:
    await workerLog(jobId, "ERROR", "Could not obtain keystone from sample")
    raise newException(WorkerError, "No keystone in sample")

  var processed = 0

  for (kind, path) in walkDir(savesDir):
    if kind == pcFile and not path.endsWith(".bin"):
      let baseName = extractFilename(path)
      let binPath = path & ".bin"
      if not fileExists(binPath):
        continue

      let destSave = joinPath(saveDir, baseName)
      let destBin = joinPath(saveDir, baseName & ".bin")
      copyFile(path, destSave)
      copyFile(binPath, destBin)

      await workerLog(jobId, "INFO", "Re-regioning " & baseName & "...")

      setupCredentials()
      let mntFolder = "/data/cecie_mnt_" & jobId[0..7]
      discard rmdir(mntFolder.cstring)
      discard mkdir(mntFolder.cstring, 0o777)

      let (errPath, handle) = mountSave(saveDir, baseName, mntFolder)
      if errPath != 0:
        await workerLog(jobId, "ERROR", "Mount failed for " & baseName)
        discard rmdir(mntFolder.cstring)
        removeFile(destSave)
        removeFile(destBin)
        continue

      discard setuid(0)
      let sfoPath = joinPath(mntFolder, "sce_sys/param.sfo")
      let sfoFd = open(sfoPath.cstring, O_RDWR, 0o777)
      if sfoFd != -1:
        discard sys_pwrite(sfoFd, accountId.addr, 8, Off(0x15C))
        discard close(sfoFd)

      let ksPath = joinPath(mntFolder, "sce_sys/keystone")
      let ksFd = open(ksPath.cstring, O_WRONLY or O_TRUNC, 0o777)
      if ksFd != -1:
        discard write(ksFd, keystoneData.addr, 0x400)
        discard close(ksFd)

      discard umountSave(mntFolder, handle, false)
      discard rmdir(mntFolder.cstring)

      await workerLog(jobId, "INFO", "Re-regioned " & baseName)
      processed += 1

      copyFile(destSave, joinPath(resultDir, baseName))
      copyFile(destBin, joinPath(resultDir, baseName & ".bin"))
      removeFile(destSave)
      removeFile(destBin)

  if processed == 0:
    await workerLog(jobId, "ERROR", "No saves were successfully re-regioned")
    raise newException(WorkerError, "No saves processed")

  await zipAndUploadResults(jobId, resultDir, workDir)
  removeRecursive(workDir)

proc processKeyset(jobId: string, params: JsonNode) {.async.} =
  await workerLog(jobId, "INFO", "Starting keyset check...")

  let consoleMax = getMaxKeySet()
  await workerLog(jobId, "INFO", "Console max keyset: " & $consoleMax)

  var resultJson = %*{"maxKeyset": consoleMax, "files": []}

  # Check if job has uploaded .bin files
  let workDir = WORK_DIR & "/" & jobId
  ensureDir(workDir)
  let filesDir = workDir & "/files"
  ensureDir(filesDir)
  let resultDir = workDir & "/result"
  ensureDir(resultDir)

  var hasFiles = false
  try:
    await downloadAndExtract(jobId, workDir, filesDir)
    hasFiles = true
  except WorkerError:
    await workerLog(jobId, "INFO", "No files uploaded, returning console keyset only")

  if hasFiles:
    for path in walkDirRec(filesDir):
      if path.endsWith(".bin"):
        let baseName = extractFilename(path)
        let fd = sys_open(path.cstring, O_RDONLY, 0)
        if fd == -1:
          await workerLog(jobId, "WARNING", "Could not open " & baseName)
          continue

        var sealedKey: array[96, byte]
        let bytesRead = sys_read(fd, sealedKey[0].addr, 96)
        discard sys_close(fd)

        if bytesRead < 96:
          await workerLog(jobId, "WARNING", baseName & ": too small (" & $bytesRead & " bytes), skipping")
          continue

        let fileKeyset = getKeySetFromSealedKey(sealedKey)
        let compatible = fileKeyset <= consoleMax

        await workerLog(jobId, "INFO", baseName & ": keyset " & $fileKeyset &
          (if compatible: " (compatible)" else: " (INCOMPATIBLE - needs " & $fileKeyset & ", console has " & $consoleMax & ")"))

        resultJson["files"].add(%*{
          "name": baseName,
          "keyset": fileKeyset,
          "compatible": compatible
        })

  # Write result JSON
  let resultPath = resultDir & "/keyset.json"
  let jsonStr = $resultJson
  await workerLog(jobId, "INFO", "Result: " & jsonStr)
  let outFd = sys_open(resultPath.cstring, O_CREAT or O_WRONLY or O_TRUNC, 0o777)
  if outFd != -1:
    discard sys_write(outFd, jsonStr[0].unsafeAddr, jsonStr.len)
    discard sys_close(outFd)

  await zipAndUploadResults(jobId, resultDir, workDir)
  removeRecursive(workDir)

# ---- Main worker loop ----

proc workerLoop*() {.async.} =
  log(lvlInfo, "Worker loop started, polling every ", $POLL_INTERVAL, "s")
  ensureDir(WORK_DIR)

  while true:
    try:
      let resp = await httpGet(SERVER_HOST, SERVER_HTTP_PORT,
        "/api/worker/next", authHeaders())

      if resp.status == 204:
        await sleepAsync(POLL_INTERVAL * 1000)
        continue

      if resp.status != 200:
        log(lvlError, "Worker poll failed: ", $resp.status)
        await sleepAsync(POLL_INTERVAL * 1000)
        continue

      let jobData = parseJson(resp.body)
      let jobId = jobData["id"].getStr()
      let operation = jobData["operation"].getStr()
      let params = jobData.getOrDefault("params")

      log(lvlInfo, "Worker picked up job: ", jobId, " (", operation, ")")

      await workerSetStatus(jobId, "running")

      try:
        case operation
        of "resign":
          await processResign(jobId, params)
        of "decrypt":
          await processDecrypt(jobId, params)
        of "encrypt":
          await processEncrypt(jobId, params)
        of "createsave":
          await processCreateSave(jobId, params)
        of "reregion":
          await processReregion(jobId, params)
        of "keyset":
          await processKeyset(jobId, params)
        else:
          await workerLog(jobId, "ERROR", "Unknown operation: " & operation)
          await workerSetStatus(jobId, "failed", "Unknown operation")
          continue

        # Process completed successfully
        await workerSetStatus(jobId, "done")
        await workerLog(jobId, "INFO", "Done! Your files are ready for download.")
      except WorkerError as e:
        log(lvlError, "Worker job failed: ", e.msg)
        await workerSetStatus(jobId, "failed", e.msg)
        # Clean up work directory
        removeRecursive(WORK_DIR & "/" & jobId)
      except CatchableError as e:
        log(lvlError, "Worker job crashed: ", e.msg)
        await workerLog(jobId, "ERROR", "Internal error: " & e.msg)
        await workerSetStatus(jobId, "failed", e.msg)
        removeRecursive(WORK_DIR & "/" & jobId)

    except CatchableError as e:
      log(lvlError, "Worker poll error: ", e.msg)

    await sleepAsync(POLL_INTERVAL * 1000)
