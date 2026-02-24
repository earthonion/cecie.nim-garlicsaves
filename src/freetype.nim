{.passl: "-lSceFreeType".}
{.passc: "-include proto-include.h".}

type
  FT_Library* {.importc: "FT_Library", header: "proto-include.h".} = pointer
  FT_Face* = ptr FT_FaceRec
  FT_GlyphSlot* = ptr FT_GlyphSlotRec

  FT_Vector* {.importc: "FT_Vector", header: "freetype/freetype.h".} = object
    x*: clong
    y*: clong

  FT_Bitmap* {.importc: "FT_Bitmap", header: "freetype/freetype.h".} = object
    rows*: cuint
    width*: cuint
    pitch*: cint
    buffer*: ptr UncheckedArray[uint8]
    num_grays*: cushort
    pixel_mode*: uint8
    palette_mode*: uint8
    palette*: pointer

  FT_Glyph_Metrics* {.importc: "FT_Glyph_Metrics", header: "freetype/freetype.h".} = object
    width*: clong
    height*: clong
    horiBearingX*: clong
    horiBearingY*: clong
    horiAdvance*: clong
    vertBearingX*: clong
    vertBearingY*: clong
    vertAdvance*: clong

  FT_Generic* {.importc: "FT_Generic", header: "freetype/freetype.h".} = object
    data*: pointer
    finalizer*: pointer

  FT_GlyphSlotRec* {.importc: "struct FT_GlyphSlotRec_", header: "freetype/freetype.h".} = object
    library*: FT_Library
    face*: FT_Face
    next*: FT_GlyphSlot
    reserved*: cuint
    generic*: FT_Generic
    metrics*: FT_Glyph_Metrics
    linearHoriAdvance*: clong
    linearVertAdvance*: clong
    advance*: FT_Vector
    format*: culong
    bitmap*: FT_Bitmap
    bitmap_left*: cint
    bitmap_top*: cint

  FT_FaceRec* {.importc: "struct FT_FaceRec_", header: "freetype/freetype.h".} = object
    num_faces*: clong
    face_index*: clong
    face_flags*: clong
    style_flags*: clong
    num_glyphs*: clong
    family_name*: cstring
    style_name*: cstring
    num_fixed_sizes*: cint
    available_sizes*: pointer
    num_charmaps*: cint
    charmaps*: pointer
    generic*: FT_Generic
    bbox*: array[4, clong]  # FT_BBox
    units_per_EM*: cushort
    ascender*: cshort
    descender*: cshort
    height*: cshort
    max_advance_width*: cshort
    max_advance_height*: cshort
    underline_position*: cshort
    underline_thickness*: cshort
    glyph*: FT_GlyphSlot

const
  FT_LOAD_DEFAULT* = 0
  FT_RENDER_MODE_NORMAL* = 0

proc FT_Init_FreeType*(lib: ptr FT_Library): cint {.importc, header: "proto-include.h".}
proc FT_Done_FreeType*(lib: FT_Library): cint {.importc, header: "proto-include.h".}
proc FT_New_Face*(lib: FT_Library, path: cstring, faceIndex: clong, face: ptr FT_Face): cint {.importc, header: "proto-include.h".}
proc FT_Done_Face*(face: FT_Face): cint {.importc, header: "proto-include.h".}
proc FT_Set_Pixel_Sizes*(face: FT_Face, width: cuint, height: cuint): cint {.importc, header: "proto-include.h".}
proc FT_Get_Char_Index*(face: FT_Face, charcode: culong): cuint {.importc, header: "proto-include.h".}
proc FT_Load_Glyph*(face: FT_Face, glyphIndex: cuint, loadFlags: uint32): cint {.importc, header: "proto-include.h".}
proc FT_Render_Glyph*(slot: FT_GlyphSlot, renderMode: cint): cint {.importc, header: "proto-include.h".}
