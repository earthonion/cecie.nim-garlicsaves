const
  CWD_KEEP* = 0
  CWD_ROOT* = 1
  CWD_RESET* = 2
proc jbc_run_as_root_in_sandbox*(fn, arg: pointer) {.cdecl, importc: "jbc_run_as_root_in_sandbox",
                                        header: "libjbc.h".}

proc jbc_run_as_root*(fn: pointer; arg: pointer;
                      cwd_mode: cint) {.cdecl, importc: "jbc_run_as_root",
                                        header: "libjbc.h".}
proc jbc_mount_in_sandbox*(system_path: cstring; mnt_name: cstring): cint {.
    cdecl, importc: "jbc_mount_in_sandbox", header: "libjbc.h".}
proc jbc_unmount_in_sandbox*(mnt_name: cstring): cint {.cdecl,
    importc: "jbc_unmount_in_sandbox", header: "libjbc.h".}

