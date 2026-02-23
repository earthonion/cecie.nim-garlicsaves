type
  jbc_cred* {.importc: "jbc_cred", header: "libjbc.h", bycopy.} = object
    uid* {.importc: "uid".}: int
    ruid* {.importc: "ruid".}: int
    svuid* {.importc: "svuid".}: int
    rgid* {.importc: "rgid".}: int
    svgid* {.importc: "svgid".}: int
    prison* {.importc: "prison".}: uint64
    cdir* {.importc: "cdir".}: uint64
    rdir* {.importc: "rdir".}: uint64
    jdir* {.importc: "jdir".}: uint64
    sceProcType* {.importc: "sceProcType".}: uint64
    sonyCred* {.importc: "sonyCred".}: uint64
    sceProcCap* {.importc: "sceProcCap".}: uint64


type jbc_ucred* {.bycopy.} = object
    cr_ref*: uint32
    ##  reference count
    cr_uid*: int32
    ##  effective user id
    cr_ruid*: int32
    ##  real user id
    cr_svuid*: int32
    ##  saved user id
    cr_ngroups*: cint
    ##  number of groups
    cr_rgid*: int32
    ##  real group id
    cr_svgid*: int32
    ##  saved group id
    cr_uidinfo*: pointer
    ##  per euid resource consumption
    cr_ruidinfo*: pointer
    ##  per ruid resource consumption
    cr_prison*: pointer
    ##  jail(2)
    cr_loginclass*: pointer
    ##  login class
    cr_flags*: uint32
    ##  credential flags
    cr_pspare2*: array[2, pointer]
    ##  general use 2
    cr_sceAuthID*: uint64
    ##  sony app authorization id
    cr_sceCaps*: array[0x04, uint64]
    ##  sony app capabilities
    cr_sceAttr*: array[0x04, uint64]
    ##  sony app attributes
    cr_unk0A0*: array[0x48, char]


proc jbc_get_prison0*(): uint64 {.cdecl, importc: "jbc_get_prison0",
                                     header: "libjbc.h".}
proc jbc_get_rootvnode*(): uint64 {.cdecl, importc: "jbc_get_rootvnode",
                                       header: "libjbc.h".}
proc jbc_get_cred*(a1: ptr jbc_cred): cint {.cdecl, importc: "jbc_get_cred",
    header: "libjbc.h".}
proc jbc_get_ucred*(a1: ptr jbc_ucred): cint {.cdecl, importc: "jbc_get_ucred", header: "libjbc.h"}

proc jbc_jailbreak_cred*(a1: ptr jbc_cred): cint {.cdecl,
    importc: "jbc_jailbreak_cred", header: "libjbc.h".}
proc jbc_set_cred*(a1: ptr jbc_cred): cint {.cdecl, importc: "jbc_set_cred",
    header: "libjbc.h".}
