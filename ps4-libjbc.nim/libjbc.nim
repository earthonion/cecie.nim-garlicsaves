import "libjbc/private/utils"
import "libjbc/private/jailbreak"
import "libjbc/private/kernelrw"
import os
import macros
import posix
{.passl: "-ljbc".}

type ProcessCredentials* = jbc_ucred
type LimitedProcessCredentials* = jbc_cred

proc sudo_call*(cb: proc {.closure.}) = 
  jbc_run_as_root(rawProc(cb), rawEnv(cb), CWD_KEEP)

proc sudo_call_sandbox*(cb: proc {.closure.}) =
  jbc_run_as_root_in_sandbox(rawProc(cb), rawEnv(cb))

template sudo*(body:untyped) {.dirty.} =
  sudo_call_sandbox(proc() {.closure.} =
    body)

template sudo_escape*(body:untyped) {.dirty.} =
  sudo_call(proc() {.closure.} =
    body)

proc sudo_mount*(system_path: string, local_path: string) : cint =
 jbc_mount_in_sandbox(system_path.cstring, local_path.cstring)

proc sudo_unmount*(local_path: string) : cint =
  jbc_unmount_in_sandbox(local_path.string)

proc get_prison0*(): uint64 =
  jbc_get_prison0()

proc get_rootvnode*(): uint64 =
  jbc_get_rootvnode()


proc get_td*(): uint64 = 
  return jbc_krw_get_td()

proc kexec_call*(cb: proc {.closure.}) =
  discard jbc_krw_kcall(cast[uint64](rawProc(cb)), rawEnv(cb))

proc get_ucred*(): ProcessCredentials =
  var pc : ProcessCredentials
  discard jbc_get_ucred(addr(pc))
  return pc

proc get_cred*(): LimitedProcessCredentials = 
  var pc : LimitedProcessCredentials
  discard jbc_get_cred(addr(pc))
  return pc

proc set_cred*(cred: LimitedProcessCredentials): cint = 
  jbc_set_cred(addr(cred))

template kexec*(body:untyped) {.dirty.} =
  kexec_call(proc() {.closure.} =
    body)


