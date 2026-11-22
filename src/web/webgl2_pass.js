// WebGL2 (#version 300 es) shaders, pipelines, bind groups, and render passes.

const SAMPLER_UNITS = [
  ["u_frame_tex", 0],
  ["u_external_source", 0],
  ["u_instances", 1],
  ["u_gradients", 2],
  ["u_source0", 2],
  ["u_atlas", 3],
  ["u_source1", 3],
  ["u_images", 4],
  ["u_lut", 5],
  ["u_source_lut", 6],
];

const PIPELINE_KINDS = {
  0: { vs: "ENTRY_QUAD_VS", fs: "ENTRY_QUAD_FS", strip: true, hole: false, blend: true },
  1: { vs: "ENTRY_QUAD_VS", fs: "ENTRY_QUAD_FS", strip: true, hole: true, blend: true },
  2: { vs: "ENTRY_QUAD_VS", fs: "ENTRY_GLASS_FS", strip: true, hole: false, blend: true },
  3: { vs: "ENTRY_PASS_VS", fs: "ENTRY_DOWN_FS", strip: false, hole: false, blend: false },
  4: { vs: "ENTRY_PASS_VS", fs: "ENTRY_BLUR_FS", strip: false, hole: false, blend: false },
  5: { vs: "ENTRY_QUAD_VS", fs: "ENTRY_EXTERNAL_FS", strip: true, hole: false, blend: true },
  8: { vs: "ENTRY_PASS_VS", fs: "ENTRY_POST_FS", strip: false, hole: false, blend: false },
  9: { vs: "ENTRY_PASS_VS", fs: "ENTRY_POST_EXTERNAL_FS", strip: false, hole: false, blend: false },
};

function makePreamble(stageMacro, entryMacro) {
  return `#version 300 es\n#define ${stageMacro} 1\n#define ${entryMacro} 1\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp sampler3D;\n`;
}

function compileStage(gl, type, source, diagnostics, label) {
  const sh = gl.createShader(type);
  if (!sh) {
    if (!gl.isContextLost()) diagnostics.push(`WebGL2 createShader failed (${label})`);
    return null;
  }
  gl.shaderSource(sh, source);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    if (!gl.isContextLost()) {
      diagnostics.push(`GLSL ${label} compile error: ${gl.getShaderInfoLog(sh) || "unknown"}`);
    }
    gl.deleteShader(sh);
    return null;
  }
  return sh;
}

export function createPassOps(state) {
  const bound2D = [null, null, null, null, null];
  const decoder = new TextDecoder();

  function bindTex2D(gl, unit, glTex) {
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, glTex);
    if (unit < bound2D.length) bound2D[unit] = glTex;
  }

  function bindTex3D(gl, unit, glTex) {
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_3D, glTex);
  }

  const imports = {
    sampler_create(filter) {
      const gl = state.gl, gen = state.generation;
      const glSampler = gl.createSampler();
      const mode = filter ? gl.LINEAR : gl.NEAREST;
      gl.samplerParameteri(glSampler, gl.TEXTURE_MIN_FILTER, mode);
      gl.samplerParameteri(glSampler, gl.TEXTURE_MAG_FILTER, mode);
      gl.samplerParameteri(glSampler, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.samplerParameteri(glSampler, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.samplerParameteri(glSampler, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
      return state.objects.put({
        kind: "sampler",
        glSampler,
        destroy() {
          if (glSampler && state.canDelete(gl, gen)) gl.deleteSampler(glSampler);
        },
      });
    },

    shader_create(ptr, len) {
      const raw = decoder.decode(state.bytes(ptr >>> 0, len >>> 0).slice());
      const code = raw.replace(/^\s*#version\s+300\s+es[^\n]*\n/, "");
      return state.objects.put({ kind: "shader", code });
    },

    layout_create(ptr, count) {
      const data = state.words(ptr >>> 0, (count >>> 0) * 3);
      const entries = [];
      for (let i = 0; i < count; i++) {
        entries.push({
          binding: data[i * 3],
          visibility: data[i * 3 + 1],
          kind: data[i * 3 + 2],
        });
      }
      return state.objects.put({ kind: "layout", entries });
    },

    pipeline_create(ptr) {
      const gl = state.gl, gen = state.generation;
      const [shader, layout, _f, kind, sampleLayout] = state.words(ptr >>> 0, 5);
      const shaderObj = state.get(shader);
      state.get(layout);
      if (sampleLayout) state.get(sampleLayout);
      const spec = PIPELINE_KINDS[kind];
      if (!spec) {
        state.diagnostics.push(`Unsupported WebGL2 pipeline kind ${kind}`);
        return state.objects.put({ kind: "pipeline", linked: false });
      }
      const vs = compileStage(gl, gl.VERTEX_SHADER, makePreamble("STAGE_VS", spec.vs) + shaderObj.code, state.diagnostics, `${spec.vs}`);
      const fs = compileStage(gl, gl.FRAGMENT_SHADER, makePreamble("STAGE_FS", spec.fs) + shaderObj.code, state.diagnostics, `${spec.fs}`);
      let prog = null, linked = false, uFirstInstanceLoc = null, uFirstInstanceIsUint = false;
      if (vs && fs) {
        prog = gl.createProgram();
        if (prog) {
          gl.attachShader(prog, vs);
          gl.attachShader(prog, fs);
          gl.linkProgram(prog);
          gl.detachShader(prog, vs);
          gl.detachShader(prog, fs);
          linked = Boolean(gl.getProgramParameter(prog, gl.LINK_STATUS));
          if (!linked && !gl.isContextLost()) {
            state.diagnostics.push(`GLSL link error (${spec.vs}/${spec.fs}): ${gl.getProgramInfoLog(prog) || "unknown"}`);
          }
        } else if (!gl.isContextLost()) {
          state.diagnostics.push("WebGL2 createProgram failed");
        }
      }
      if (vs) gl.deleteShader(vs);
      if (fs) gl.deleteShader(fs);

      if (linked && prog) {
        for (const blockName of ["ParamsBlock", "PostBlock"]) {
          const blockIdx = gl.getUniformBlockIndex(prog, blockName);
          if (blockIdx !== gl.INVALID_INDEX) gl.uniformBlockBinding(prog, blockIdx, 0);
        }
        if (gl.getProgramParameter(prog, gl.ACTIVE_UNIFORM_BLOCKS) === 1) {
          gl.uniformBlockBinding(prog, 0, 0);
        }
        gl.useProgram(prog);
        for (const [name, unit] of SAMPLER_UNITS) {
          const loc = gl.getUniformLocation(prog, name);
          if (loc !== null) gl.uniform1i(loc, unit);
        }
        uFirstInstanceLoc = gl.getUniformLocation(prog, "u_first_instance");
        if (uFirstInstanceLoc !== null) {
          const activeCount = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
          for (let i = 0; i < activeCount; i++) {
            const info = gl.getActiveUniform(prog, i);
            if (info && info.name === "u_first_instance") {
              uFirstInstanceIsUint = info.type === gl.UNSIGNED_INT;
              break;
            }
          }
        }
      }

      return state.objects.put({
        kind: "pipeline",
        prog,
        linked,
        topology: spec.strip ? gl.TRIANGLE_STRIP : gl.TRIANGLES,
        blend: spec.blend ? [spec.hole ? gl.ZERO : gl.ONE, gl.ONE_MINUS_SRC_ALPHA] : null,
        uFirstInstanceLoc,
        uFirstInstanceIsUint,
        destroy() {
          if (prog && state.canDelete(gl, gen)) gl.deleteProgram(prog);
        },
      });
    },

    bind_group_create(layout, ptr, count) {
      const data = state.words(ptr >>> 0, (count >>> 0) * 5);
      const entries = [];
      const byBinding = {};
      for (let i = 0; i < count; i++) {
        const base = i * 5;
        const entry = {
          binding: data[base],
          entryKind: data[base + 1],
          resource: state.get(data[base + 2]),
          offset: data[base + 3],
          size: data[base + 4],
        };
        entries.push(entry);
        byBinding[entry.binding] = entry;
      }
      const isPost = Boolean(byBinding[7] || (byBinding[4] && byBinding[4].entryKind === 2));
      return state.objects.put({
        kind: "bind_group",
        layout: state.get(layout),
        entries,
        byBinding,
        isPost,
      });
    },

    encoder_begin() {
      state.beginEncode();
      return state.transient({ kind: "encoder", presentCanvas: false });
    },

    pass_begin(enc, view, load, r, g, b, a) {
      const gl = state.gl;
      const encObj = state.get(enc);
      const viewObj = state.get(view);
      const target = viewObj.texture ?? viewObj;
      if (target === state.canvasTarget) encObj.presentCanvas = true;
      state.stats.passes++;
      gl.bindVertexArray(state.vao);
      for (let u = 0; u < bound2D.length; u++) {
        if (bound2D[u] === target.glTex) bindTex2D(gl, u, state.dummyTex2D);
      }
      const fbo = state.ensureFbo(target);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.disable(gl.SCISSOR_TEST);
      gl.viewport(0, 0, target.width, target.height);
      if (!load) {
        gl.clearColor(r, g, b, a);
        gl.clear(gl.COLOR_BUFFER_BIT);
      }
      return state.transient({ kind: "pass", enc: encObj, target, pipeline: null });
    },

    pass_set_pipeline(pass, pipeline) {
      const gl = state.gl;
      const passObj = state.get(pass);
      const pipe = state.get(pipeline);
      passObj.pipeline = pipe;
      if (!pipe.linked || !pipe.prog) return;
      gl.useProgram(pipe.prog);
      if (pipe.blend) {
        gl.enable(gl.BLEND);
        gl.blendEquation(gl.FUNC_ADD);
        gl.blendFunc(pipe.blend[0], pipe.blend[1]);
      } else {
        gl.disable(gl.BLEND);
      }
    },

    pass_set_bind_group(_pass, index, group, dynamicOffset) {
      const gl = state.gl;
      const bg = state.get(group);
      const b = bg.byBinding;
      if (index === 0) {
        if (b[0]) {
          const ubo = b[0].resource;
          const dyn = (dynamicOffset >>> 0) === 0xffffffff ? 0 : (dynamicOffset >>> 0);
          const off = b[0].offset + dyn;
          const sz = Math.min(b[0].size || 256, ubo.byteLength - off);
          if (sz > 0) gl.bindBufferRange(gl.UNIFORM_BUFFER, 0, ubo.glBuf, off, sz);
        }
        if (!bg.isPost) {
          if (b[1]) { bindTex2D(gl, 1, b[1].resource.glTex); gl.bindSampler(1, null); }
          if (b[2]) { bindTex2D(gl, 2, b[2].resource.glTex); gl.bindSampler(2, null); }
          const samp = b[5]?.resource?.glSampler ?? state.linearClampSampler;
          if (b[3]) { bindTex2D(gl, 3, (b[3].resource.texture ?? b[3].resource).glTex); gl.bindSampler(3, samp); }
          if (b[4]) { bindTex2D(gl, 4, (b[4].resource.texture ?? b[4].resource).glTex); gl.bindSampler(4, samp); }
        } else {
          const pointSamp = b[4]?.resource?.glSampler ?? state.nearestClampSampler;
          const linSamp = b[7]?.resource?.glSampler ?? state.linearClampSampler;
          if (b[2]) { bindTex2D(gl, 2, (b[2].resource.texture ?? b[2].resource).glTex); gl.bindSampler(2, pointSamp); }
          if (b[3]) { bindTex2D(gl, 3, (b[3].resource.texture ?? b[3].resource).glTex); gl.bindSampler(3, linSamp); }
          if (b[5]) { bindTex3D(gl, 5, (b[5].resource.texture ?? b[5].resource).glTex); gl.bindSampler(5, linSamp); }
          if (b[6]) { bindTex3D(gl, 6, (b[6].resource.texture ?? b[6].resource).glTex); gl.bindSampler(6, linSamp); }
        }
      } else if (index === 1) {
        const entry = bg.entries[0];
        if (entry) {
          const tex = entry.resource.texture ?? entry.resource;
          bindTex2D(gl, 0, tex.glTex);
          gl.bindSampler(0, state.linearClampSampler);
        }
      }
    },

    pass_draw(pass, vertices, instances, firstInstance) {
      const gl = state.gl;
      const passObj = state.get(pass);
      const pipe = passObj.pipeline;
      if (!pipe || !pipe.linked || !pipe.prog || vertices === 0 || instances === 0) return;
      state.recordDraw();
      if (pipe.uFirstInstanceLoc !== null) {
        if (pipe.uFirstInstanceIsUint) gl.uniform1ui(pipe.uFirstInstanceLoc, firstInstance >>> 0);
        else gl.uniform1i(pipe.uFirstInstanceLoc, firstInstance | 0);
      }
      gl.drawArraysInstanced(pipe.topology, 0, vertices >>> 0, instances >>> 0);
    },

    pass_end(_pass) {
      const gl = state.gl;
      gl.disable(gl.SCISSOR_TEST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    },

    pass_viewport(_pass, width, height) {
      state.gl.viewport(0, 0, width >>> 0, height >>> 0);
    },

    pass_scissor(_pass, x, y, width, height) {
      const gl = state.gl;
      gl.enable(gl.SCISSOR_TEST);
      gl.scissor(x | 0, y | 0, width >>> 0, height >>> 0);
    },

    encoder_copy_texture(enc, src, dst, width, height) {
      const gl = state.gl;
      const encObj = state.get(enc);
      const srcTex = state.get(src);
      const dstTex = state.get(dst);
      if (dstTex === state.canvasTarget) encObj.presentCanvas = true;
      const srcFbo = state.ensureFbo(srcTex);
      const dstFbo = state.ensureFbo(dstTex);
      const w = width >>> 0, h = height >>> 0;
      gl.disable(gl.SCISSOR_TEST);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, srcFbo);
      gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, dstFbo);
      gl.blitFramebuffer(0, 0, w, h, 0, 0, w, h, gl.COLOR_BUFFER_BIT, gl.NEAREST);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
      gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    },

    encoder_submit(enc) {
      const gl = state.gl;
      const encObj = state.get(enc);
      try {
        if (encObj.presentCanvas && state.canvasTarget) {
          const w = state.canvasTarget.width, h = state.canvasTarget.height;
          gl.disable(gl.SCISSOR_TEST);
          gl.bindFramebuffer(gl.READ_FRAMEBUFFER, state.canvasTarget.fbo);
          gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
          gl.blitFramebuffer(0, 0, w, h, 0, h, w, 0, gl.COLOR_BUFFER_BIT, gl.NEAREST);
          gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
        }
      } finally {
        state.finishSubmit();
      }
    },

    read_begin(tex, width, height, _f, dest, token) {
      const gl = state.gl, w = width >>> 0, h = height >>> 0, byteLen = w * h * 4;
      try {
        const fbo = state.ensureFbo(state.get(tex)), rgba = new Uint8Array(byteLen);
        gl.disable(gl.SCISSOR_TEST);
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, fbo);
        gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, rgba);
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
        queueMicrotask(() => {
          try {
            const dst = state.bytes(dest >>> 0, byteLen);
            for (let i = 0; i < byteLen; i += 4) {
              dst[i] = rgba[i + 2]; dst[i + 1] = rgba[i + 1]; dst[i + 2] = rgba[i]; dst[i + 3] = rgba[i + 3];
            }
            state.done(token, 0);
          } catch (err) { state.diagnostics.push(`Readback: ${err.message}`); state.done(token, 1); }
        });
      } catch (err) { state.diagnostics.push(`Readback: ${err.message}`); queueMicrotask(() => state.done(token, 1)); }
    },
  };

  return {
    imports,
    resetPassState() { bound2D.fill(null); },
  };
}
