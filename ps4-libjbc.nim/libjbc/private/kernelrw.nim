
proc jbc_krw_kcall*(fn: uint64): uint64 {.varargs, cdecl,
    importc: "jbc_krw_kcall", header: "libjbc.h".}
proc jbc_krw_get_td*(): uint64 {.cdecl, importc: "jbc_krw_get_td",
                                    header: "libjbc.h".}
type
  KmemKind* {.size: sizeof(cint).} = enum
    USERSPACE, KERNEL_HEAP, KERNEL_TEXT


proc jbc_krw_memcpy*(dst: uint64; src: uint64; sz: csize_t; kind: KmemKind): cint {.
    cdecl, importc: "jbc_krw_memcpy", header: "libjbc.h".}
proc jbc_krw_read64*(p: uint64; kind: KmemKind): uint64 {.cdecl,
    importc: "jbc_krw_read64", header: "libjbc.h".}
proc jbc_krw_write64*(p: uint64; kind: KmemKind; val: uint64): cint {.
    cdecl, importc: "jbc_krw_write64", header: "libjbc.h".}
