# Super Mario Odyssey (0100000000010000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py.
import struct

from nso_asm import ADDI, ADRP, B

_build = 'b424be150a8e7d78701cbe7a439d9ebf'   # update 1.4.1 (v393216) main
_aspect_state = 0x280   # float desired drawable width / height (written by host loader.c)
_aspect_ack = 0x284     # float host-visible applied aspect (0 = stock 16:9)


def _f32(value): return struct.unpack('<I', struct.pack('<f', value))[0]
def _movz(wd, imm): return 0x52800000 | ((imm & 0xffff) << 5) | wd
def _movk16(wd, imm): return 0x72a00000 | ((imm & 0xffff) << 5) | wd
def _fmov_sw(sd, wn): return 0x1e270000 | (wn << 5) | sd
def _fmul(sd, sn, sm): return 0x1e200800 | (sm << 16) | (sn << 5) | sd
def _fsub(sd, sn, sm): return 0x1e203800 | (sm << 16) | (sn << 5) | sd
def _fabs(sd, sn): return 0x1e20c000 | (sn << 5) | sd
def _fcmp(sn, sm): return 0x1e202000 | (sm << 16) | (sn << 5)
def _cmp_w(wn, wm): return 0x6b00001f | (wm << 16) | (wn << 5)
def _ldr_w(wt, xn, off=0): return 0xb9400000 | ((off // 4) << 10) | (xn << 5) | wt
def _ldr_s(st, xn, off=0): return 0xbd400000 | ((off // 4) << 10) | (xn << 5) | st
def _str_s(st, xn, off=0): return 0xbd000000 | ((off // 4) << 10) | (xn << 5) | st
def _ldar_w(wt, xn): return 0x88dffc00 | (xn << 5) | wt
def _stlr_w(wt, xn): return 0x889ffc00 | (xn << 5) | wt
def _cbz_w(wt, frm, to): return 0x34000000 | ((((to - frm) >> 2) & 0x7ffff) << 5) | wt
def _b_cond(frm, to, cond): return 0x54000000 | ((((to - frm) >> 2) & 0x7ffff) << 5) | cond


def _load_f32(words, sreg, value):
    bits = _f32(value)
    words.extend((_movz(16, bits), _movk16(16, bits >> 16), _fmov_sw(sreg, 16)))


def _state_addr(ctx, words, xreg, off):
    pc = ctx.here() + len(words) * 4
    words.extend((ADRP(xreg, pc, ctx.state + off), ADDI(xreg, xreg, (ctx.state + off) & 0xfff)))


def _append_stub(ctx, site, words, reason):
    start = ctx.here()
    for w in words: ctx.emit(w)
    ctx.emit(B(ctx.here(), site + 4))
    ctx.put(site, [B(site, start)], reason)


def _scene_aspect(ctx):
    # al::getSceneFrameBufferMainAspect (0x74d2ec: fdiv s0, s0, s1; 0x74d2f0: ret).
    # Widens only ~16:9 scene calls so 1:1 snapshot/cube targets stay untouched; publishes applied aspect at +0x284.
    site = 0x74d2ec
    ctx.site(site, '0018211e')
    w = [0x1e211800]
    _load_f32(w, 16, 16.0 / 9.0)
    w.extend((_fsub(16, 0, 16), _fabs(16, 16)))
    _load_f32(w, 17, 0.01)
    w.append(_fcmp(16, 17))
    not_wide = len(w); w.append(0)
    _state_addr(ctx, w, 17, _aspect_state)
    w.append(_ldar_w(16, 17))
    off_branch = len(w); w.append(0)
    w.append(_fmov_sw(0, 16))
    ack = len(w)
    _state_addr(ctx, w, 17, _aspect_ack)
    w.append(_stlr_w(16, 17))
    end = len(w)
    w[not_wide] = _b_cond(ctx.here() + not_wide * 4, ctx.here() + end * 4, 2)   # cs: |aspect - 16/9| >= 0.01
    w[off_branch] = _cbz_w(16, ctx.here() + off_branch * 4, ctx.here() + ack * 4)
    _append_stub(ctx, site, w, 'camera projection: widen 16:9 framebuffer aspect to active drawable ratio (ASPECT_STATE)')


def _ortho_width(ctx, site):
    # LayoutOrthoSetup (0x6330d4 and 0x6330fc: ucvtf s0, w0 after bl 0x74f170).
    # Multiplies layout ortho width by (wide * 9/16) so 2D space matches screen aspect and 16:9 HUD widgets stay unstretched.
    ctx.site(site, '0000231e')
    w = [0x1e230000]
    _state_addr(ctx, w, 17, _aspect_state)
    w.append(_ldar_w(16, 17))
    disabled = len(w); w.append(0)
    w.append(_fmov_sw(16, 16))
    w.append(_fmul(0, 0, 16))
    _load_f32(w, 16, 9.0 / 16.0)
    w.append(_fmul(0, 0, 16))
    end = len(w)
    w[disabled] = _cbz_w(16, ctx.here() + disabled * 4, ctx.here() + end * 4)
    _append_stub(ctx, site, w, 'full-screen 2D layout: widen ortho projection horizontally to match active drawable ratio')


def _backdrop_pane(ctx):
    # nn::ui2d::Pane::Pane (0x908c3c: ldrb w8, [x23, #0x0] right after mSize [x19+0x50..0x54] is stored).
    # Widens 1280x720 non-RootPane quads (fades, masks, background plates) so edges stay covered in widened ortho space.
    site = 0x908c3c
    ctx.site(site, 'e8024039')
    w = [0x394002e8]
    _state_addr(ctx, w, 17, _aspect_state)
    w.append(_ldar_w(16, 17))
    b_off = len(w); w.append(0)
    w.append(_ldr_s(0, 19, 0x50))
    _load_f32(w, 16, 1279.0)
    w.append(_fcmp(0, 16))
    b_wlo = len(w); w.append(0)
    _load_f32(w, 16, 1300.0)
    w.append(_fcmp(0, 16))
    b_whi = len(w); w.append(0)
    w.append(_ldr_s(1, 19, 0x54))
    _load_f32(w, 16, 719.0)
    w.append(_fcmp(1, 16))
    b_hlo = len(w); w.append(0)
    _load_f32(w, 16, 740.0)
    w.append(_fcmp(1, 16))
    b_hhi = len(w); w.append(0)
    w.extend((ADDI(17, 19, 0xd1), _ldr_w(17, 17, 0), _movz(16, 0x6f52), _movk16(16, 0x746f), _cmp_w(17, 16)))
    b_root = len(w); w.append(0)
    _state_addr(ctx, w, 17, _aspect_state)
    w.extend((_ldar_w(16, 17), _fmov_sw(16, 16), _fmul(0, 0, 16)))
    _load_f32(w, 16, 9.0 / 16.0)
    w.extend((_fmul(0, 0, 16), _str_s(0, 19, 0x50)))
    end = len(w)
    w[b_off] = _cbz_w(16, ctx.here() + b_off * 4, ctx.here() + end * 4)
    w[b_wlo] = _b_cond(ctx.here() + b_wlo * 4, ctx.here() + end * 4, 11)   # lt (or NaN)
    w[b_whi] = _b_cond(ctx.here() + b_whi * 4, ctx.here() + end * 4, 8)    # hi (or NaN)
    w[b_hlo] = _b_cond(ctx.here() + b_hlo * 4, ctx.here() + end * 4, 11)
    w[b_hhi] = _b_cond(ctx.here() + b_hhi * 4, ctx.here() + end * 4, 8)
    w[b_root] = _b_cond(ctx.here() + b_root * 4, ctx.here() + end * 4, 0)   # eq: "Root..."
    _append_stub(ctx, site, w, 'full-screen fades and backdrops: widen 1280x720 non-RootPane quads to cover widened ortho space')


def widescreen(ctx):
    _scene_aspect(ctx)
    _ortho_width(ctx, 0x6330d4)
    _ortho_width(ctx, 0x6330fc)
    _backdrop_pane(ctx)


FRAME_STEP = {
    _build: widescreen,
}

CAPABILITIES = {
    _build: ('CAMERA_ASPECT',),
}

BINDING = [
    {'what': 'native landscape camera, widened 2D layout ortho and backdrop pane sizing', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': 'the exact-build scene aspect getter, LayoutOrthoSetup and nn::ui2d::Pane::Pane sites on SMO 1.4.1 main',
     'checked': 'verified all four hook addresses, register liveness and opcodes directly in v2 __dmmainx0; not yet run on device'},
]
