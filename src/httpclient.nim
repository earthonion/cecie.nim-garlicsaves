import asyncdispatch
import asyncnet
import json
import strutils
import posix
import "./syscalls"

const CHUNK_UPLOAD_SIZE* = 5 * 1024 * 1024  # 5MB - PS4 uploads at ~500KB/s, needs to finish within server timeout

type HttpResponse* = tuple[status: int, headers: seq[(string, string)], body: string]

proc parseHttpResponse(raw: string): HttpResponse =
  var status = 0
  var headers: seq[(string, string)] = @[]
  var body = ""

  let headerEnd = raw.find("\r\n\r\n")
  if headerEnd == -1:
    return (0, @[], raw)

  let headerSection = raw[0 ..< headerEnd]
  body = raw[headerEnd + 4 .. ^1]

  let lines = headerSection.split("\r\n")
  if lines.len > 0:
    # Parse status line: HTTP/1.x STATUS_CODE ...
    let parts = lines[0].split(" ", 2)
    if parts.len >= 2:
      status = parseInt(parts[1])

    for i in 1 ..< lines.len:
      let colonPos = lines[i].find(":")
      if colonPos != -1:
        let key = lines[i][0 ..< colonPos].strip()
        let val = lines[i][colonPos + 1 .. ^1].strip()
        headers.add((key, val))

  result = (status, headers, body)

proc getHeaderValue(headers: seq[(string, string)], key: string): string =
  for (k, v) in headers:
    if k.toLowerAscii() == key.toLowerAscii():
      return v
  return ""

proc recvAll(sock: AsyncSocket, contentLength: int): Future[string] {.async.} =
  ## Read exactly contentLength bytes
  var buf = ""
  while buf.len < contentLength:
    let remaining = contentLength - buf.len
    let chunk = await sock.recv(min(remaining, 32768))
    if chunk.len == 0:
      break
    buf.add(chunk)
  return buf

proc recvHttpResponse(sock: AsyncSocket): Future[HttpResponse] {.async.} =
  ## Read HTTP response: headers first, then body based on Content-Length
  var headerBuf = ""
  # Read until we get \r\n\r\n
  while true:
    let c = await sock.recv(1)
    if c.len == 0:
      break
    headerBuf.add(c)
    if headerBuf.endsWith("\r\n\r\n"):
      break

  let parsed = parseHttpResponse(headerBuf)
  let clStr = getHeaderValue(parsed.headers, "content-length")
  if clStr.len > 0:
    let cl = parseInt(clStr)
    if cl > 0:
      let body = await recvAll(sock, cl)
      return (parsed.status, parsed.headers, body)

  # No content-length — read until close
  var body = ""
  while true:
    let chunk = await sock.recv(32768)
    if chunk.len == 0:
      break
    body.add(chunk)
  return (parsed.status, parsed.headers, body)

proc httpRequest*(host: string, port: int, meth: string, path: string,
                  body: string = "", contentType: string = "",
                  headers: seq[(string, string)] = @[]): Future[HttpResponse] {.async.} =
  let sock = newAsyncSocket()
  await sock.connect(host, Port(port))

  var req = meth & " " & path & " HTTP/1.0\r\n"
  req.add("Host: " & host & "\r\n")
  for (k, v) in headers:
    req.add(k & ": " & v & "\r\n")
  if body.len > 0:
    if contentType.len > 0:
      req.add("Content-Type: " & contentType & "\r\n")
    req.add("Content-Length: " & $body.len & "\r\n")
  req.add("\r\n")
  if body.len > 0:
    req.add(body)

  await sock.send(req)
  result = await recvHttpResponse(sock)
  sock.close()

proc httpGet*(host: string, port: int, path: string,
              headers: seq[(string, string)] = @[]): Future[HttpResponse] {.async.} =
  return await httpRequest(host, port, "GET", path, headers = headers)

proc httpPost*(host: string, port: int, path: string,
               body: string, contentType: string = "application/json",
               headers: seq[(string, string)] = @[]): Future[HttpResponse] {.async.} =
  return await httpRequest(host, port, "POST", path, body, contentType, headers)

proc httpDownloadToFile*(host: string, port: int, path: string,
                         destPath: string,
                         headers: seq[(string, string)] = @[]): Future[int] {.async.} =
  ## Download to a file. Returns HTTP status code.
  let sock = newAsyncSocket()
  await sock.connect(host, Port(port))

  var req = "GET " & path & " HTTP/1.0\r\n"
  req.add("Host: " & host & "\r\n")
  for (k, v) in headers:
    req.add(k & ": " & v & "\r\n")
  req.add("\r\n")
  await sock.send(req)

  # Read headers
  var headerBuf = ""
  while true:
    let c = await sock.recv(1)
    if c.len == 0:
      break
    headerBuf.add(c)
    if headerBuf.endsWith("\r\n\r\n"):
      break

  let parsed = parseHttpResponse(headerBuf)

  # Write body to file
  let fd = sys_open(destPath.cstring, O_CREAT or O_WRONLY or O_TRUNC, 0o777)
  if fd == -1:
    sock.close()
    return -1

  let clStr = getHeaderValue(parsed.headers, "content-length")
  if clStr.len > 0:
    let cl = parseInt(clStr)
    var written = 0
    while written < cl:
      let remaining = min(cl - written, 32768)
      let chunk = await sock.recv(remaining)
      if chunk.len == 0:
        break
      discard sys_write(fd, chunk.cstring, chunk.len)
      written += chunk.len
  else:
    while true:
      let chunk = await sock.recv(32768)
      if chunk.len == 0:
        break
      discard sys_write(fd, chunk.cstring, chunk.len)

  discard sys_close(fd)
  sock.close()
  return parsed.status

proc httpUploadFile*(host: string, port: int, path: string,
                     srcPath: string,
                     headers: seq[(string, string)] = @[]): Future[int] {.async.} =
  ## Upload a file as raw binary body. Returns HTTP status code.
  let fd = sys_open(srcPath.cstring, O_RDONLY, 0)
  if fd == -1:
    return -1

  let fileSize = sys_lseek(fd, Off(0), SEEK_END)
  if fileSize < 0:
    discard sys_close(fd)
    return -1
  discard sys_lseek(fd, Off(0), SEEK_SET)

  let sock = newAsyncSocket()
  await sock.connect(host, Port(port))

  var req = "POST " & path & " HTTP/1.0\r\n"
  req.add("Host: " & host & "\r\n")
  for (k, v) in headers:
    req.add(k & ": " & v & "\r\n")
  req.add("Content-Type: application/octet-stream\r\n")
  req.add("Content-Length: " & $fileSize & "\r\n")
  req.add("\r\n")
  await sock.send(req)

  var chunk: array[32768, byte]
  var remaining = int(fileSize)
  while remaining > 0:
    let toRead = min(remaining, chunk.len)
    let n = sys_read(fd, chunk[0].addr, toRead)
    if n <= 0:
      break
    await sock.send(chunk[0].addr, int(n))
    remaining -= int(n)
  discard sys_close(fd)

  let resp = await recvHttpResponse(sock)
  sock.close()
  return resp.status

proc httpUploadFileChunked*(host: string, port: int, basePath: string,
                             srcPath: string,
                             headers: seq[(string, string)] = @[],
                             onChunk: proc(i, total, chunkLen: int) = nil): Future[bool] {.async.} =
  ## Upload a file in chunks via the chunked upload API.
  ## basePath should be e.g. "/api/worker/jobs/<job_id>/result"
  let fd = sys_open(srcPath.cstring, O_RDONLY, 0)
  if fd == -1:
    return false

  let fileSize = int(sys_lseek(fd, Off(0), SEEK_END))
  if fileSize <= 0:
    discard sys_close(fd)
    return false
  discard sys_lseek(fd, Off(0), SEEK_SET)

  # 1. Init chunked upload
  let initBody = $(%*{"total_size": fileSize})
  let initResp = await httpPost(host, port, basePath & "/init",
    initBody, "application/json", headers)
  if initResp.status != 200:
    discard sys_close(fd)
    return false

  let initJson = parseJson(initResp.body)
  let uploadId = initJson["upload_id"].getStr()

  # 2. Upload chunks
  let totalChunks = (fileSize + CHUNK_UPLOAD_SIZE - 1) div CHUNK_UPLOAD_SIZE
  var chunkBuf = newString(CHUNK_UPLOAD_SIZE)

  for i in 0 ..< totalChunks:
    let chunkStart = i * CHUNK_UPLOAD_SIZE
    let chunkLen = min(CHUNK_UPLOAD_SIZE, fileSize - chunkStart)

    discard sys_lseek(fd, Off(chunkStart), SEEK_SET)

    # Read chunk into buffer
    var readTotal = 0
    while readTotal < chunkLen:
      let n = sys_read(fd, chunkBuf[readTotal].addr, chunkLen - readTotal)
      if n <= 0:
        break
      readTotal += int(n)

    if readTotal != chunkLen:
      discard sys_close(fd)
      return false

    let chunkPath = basePath & "/chunk/" & $i & "?upload_id=" & uploadId

    # Upload this chunk as raw body
    var success = false
    for attempt in 0 ..< 3:
      let sock = newAsyncSocket()
      await sock.connect(host, Port(port))

      var req = "POST " & chunkPath & " HTTP/1.0\r\n"
      req.add("Host: " & host & "\r\n")
      for (k, v) in headers:
        req.add(k & ": " & v & "\r\n")
      req.add("Content-Type: application/octet-stream\r\n")
      req.add("Content-Length: " & $chunkLen & "\r\n")
      req.add("\r\n")
      await sock.send(req)
      await sock.send(chunkBuf[0].addr, chunkLen)

      let resp = await recvHttpResponse(sock)
      sock.close()

      if resp.status == 200:
        success = true
        if onChunk != nil:
          onChunk(i, totalChunks, chunkLen)
        break

      # Exponential backoff
      await sleepAsync(1000 * (1 shl attempt))

    if not success:
      discard sys_close(fd)
      return false

  discard sys_close(fd)

  # 3. Complete
  let completeBody = $(%*{"upload_id": uploadId})
  let completeResp = await httpPost(host, port, basePath & "/complete",
    completeBody, "application/json", headers)
  return completeResp.status == 200
