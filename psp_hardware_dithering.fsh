// PSP Hardware Dithering, pass 1: framebuffer color depth + GE dithering, at render resolution.
//
// Recreates what the PSP GE (and PPSSPP's software renderer) does when writing a pixel:
//   1. add the signed 4x4 dither matrix value to the 8-bit color,
//   2. clamp and truncate to the framebuffer format (565 / 5551 / 4444),
//   3. expand back to 8 bits with bit replication, like the display controller.
// The dither pattern is locked to the PSP's 480x272 pixel grid, so at 2x+ rendering
// geometry stays high-res while the dither keeps its original, chunky look.
//
// PSP x2 runs the write twice. Many games finish the frame with a full screen pass drawn
// with dithering on (MGS Peace Walker's bloom), so every pixel, already truncated once, gets
// the matrix added and is truncated again. That darkens dark areas by a level in the
// negative matrix cells and makes the cross-hatch coarser, as on hardware.
//
// The optional blur softens only the dither: the error the dither adds to each pixel is
// Gaussian-blurred and added back to the unblurred color, so edges and textures stay sharp
// while the low-frequency part of the error (the format's banding) is kept.
// Pass 2 (psp_hardware_dithering_scale.fsh) scales the result to the screen.
//
// Settings:
//   x: color depth  0 = 32-bit 8888, 1 = 16-bit 565, 2 = 15-bit 5551, 3 = 12-bit 4444, 4 = 8-bit 332
//   y: dither       0 = off (truncate), 1 = PSP GE matrix, 2 = PSP GE matrix written twice,
//                   3 = Bayer 2x2, 4 = Bayer 4x4
//   z: pixels       0 = hi-res, dither on PSP grid, 1 = hi-res, dither on render grid,
//                   2 = native 480x272 (supersampled),
//                   3 = native 480x272 (supersampled) with the dither on the render grid,
//                   4 = native 480x272 (point sampled)
//   w: dither blur, 0-1 for a radius of 0-1.5 PSP pixels (0 = off)

#ifdef GL_ES
#extension GL_OES_standard_derivatives : enable
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#endif

uniform sampler2D sampler0;
varying vec2 v_texcoord0;

uniform vec2 u_texelDelta;
uniform vec2 u_pixelDelta;
uniform vec4 u_setting;
uniform float u_video;

// Size of the PSP framebuffer (in PSP pixels) that v_texcoord0 = 0..1 corresponds to.
// The input is usually a 480x272 crop of a wider buffer (often 512 wide). Recovered from
// how far the texcoord travels across the output rectangle, rounded so the grid can't drift.
vec2 pspBufferSize(vec2 dx, vec2 dy) {
	vec2 span;
	if (abs(dx.x) >= abs(dy.x)) {
		span = vec2(abs(dx.x) / u_pixelDelta.x, abs(dy.y) / u_pixelDelta.y);
	} else {
		// Display rotated 90 degrees: texcoord x runs along screen y.
		span = vec2(abs(dy.x) / u_pixelDelta.y, abs(dx.y) / u_pixelDelta.x);
	}
	return floor(vec2(480.0, 272.0) / max(span, vec2(1e-6)) + 0.5);
}

// Real size of one input texel in texcoords, see inputTexelDelta().
vec2 texelDelta;

// Render texels per PSP pixel, a whole number, the same on both axes.
// u_texelDelta can't be taken as is: PPSSPP reports the game framebuffer as
// bufferWidth * renderWidth / width texels wide, which is more than it really is whenever the
// game displays less than the buffer holds (MGS Peace Walker: 546 for a 512 wide buffer).
// It only ever comes out too big, so the smaller axis rounded down is the real scale. A stereo
// composite (both eyes side by side, or stacked) looks like a single 480x272 frame from the
// texcoords alone, so its stacking axis comes out doubled, which the smaller axis also skips.
float renderScale(vec2 reported, vec2 bufSize) {
	vec2 r = reported / bufSize;
	return max(floor(min(r.x, r.y) + 0.01), 1.0);
}

// The input is bufSize PSP pixels times the render scale. Along a stereo stacking axis it's
// twice that, and there the reported size is right, since it's the composite's own.
vec2 inputTexelDelta(vec2 reported, vec2 bufSize, float scale) {
	return 1.0 / mix(bufSize * scale, reported, step(1.5 * scale, reported / bufSize));
}

// Pass 2 is told the game framebuffer's size too, not this pass's, so this pass's size goes to
// it in alpha: the render scale (1-63) plus 64 x the stereo layout (1 side by side, 2 stacked),
// or 255 when the output isn't 480x272 times that.
float outputSizeCode() {
	vec2 k = floor(1.0 / u_pixelDelta + 0.5) / vec2(480.0, 272.0);
	float z = min(k.x, k.y);
	float stereo = k.x > z * 1.5 ? 1.0 : (k.y > z * 1.5 ? 2.0 : 0.0);
	vec2 stack = stereo > 1.5 ? vec2(1.0, 2.0) : (stereo > 0.5 ? vec2(2.0, 1.0) : vec2(1.0));
	vec2 err = abs(k - z * stack);
	if (z < 1.0 || z > 63.0 || z != floor(z) || max(err.x, err.y) > 0.001) {
		return 1.0;
	}
	return (z + 64.0 * stereo) / 255.0;
}

// Bayer matrices built arithmetically (no arrays, works on every backend).
float bayer2(vec2 p) {
	p = mod(p, 2.0);
	return 2.0 * abs(p.x - p.y) + p.y;
}

float bayer4(vec2 p) {
	return 4.0 * bayer2(p) + bayer2(floor(mod(p, 4.0) * 0.5));
}

vec3 formatBits(float f) {
	if (f < 0.5) return vec3(8.0);
	if (f < 1.5) return vec3(5.0, 6.0, 5.0);
	if (f < 2.5) return vec3(5.0);
	if (f < 3.5) return vec3(4.0);
	return vec3(3.0, 3.0, 2.0);
}

// Expand format levels q back to 8 bits (0-255). 4+ bit channels use bit replication like the
// PSP display path (5 bit: v<<3 | v>>2, 6 bit: v<<2 | v>>4, 4 bit: v<<4 | v).
vec3 expandTo8(vec3 q, vec3 bits) {
	vec3 replicated = q * exp2(8.0 - bits) + floor(q / exp2(max(2.0 * bits - 8.0, 0.0)));
	vec3 scaled = floor(q * 255.0 / (exp2(bits) - 1.0) + 0.5);
	return mix(scaled, replicated, step(4.0, bits));
}

// rgb: rendered color, psp: integer dither-grid coordinate, bits: per-channel format depth.
vec3 pspWritePixel(vec3 rgb, vec2 psp, vec3 bits) {
	vec3 stepSize = exp2(8.0 - bits);
	vec3 maxLevel = exp2(bits) - 1.0;
	vec3 c = floor(clamp(rgb, 0.0, 1.0) * 255.0 + 0.5);

	float type = u_setting.y;
	// FMVs are copied straight into VRAM by the PSP, they never pass through the dither.
	float video = step(0.5, u_video);

	vec3 q;
	if (type < 0.5) {
		q = floor(c / stepSize);
	} else if (type < 2.5) {
		// The SDK default matrix that nearly every game loads:
		//   -4  0 -3  1
		//    2 -2  3 -1
		//   -3  1 -4  0
		//    3 -1  2 -2
		// which is exactly floor(bayer4 / 2) - 4. Added in 8-bit space, same value for R, G and B.
		float d = (floor(bayer4(psp) * 0.5) - 4.0) * (1.0 - video);
		q = floor(clamp(c + d, 0.0, 255.0) / stepSize);
		if (type > 1.5) {
			// A second dithered write over the stored pixel, like a full screen pass.
			q = floor(clamp(expandTo8(q, bits) + d, 0.0, 255.0) / stepSize);
		}
	} else {
		// Classic ordered dither, normalized to one quantization step of each channel.
		float t;
		if (type < 3.5) {
			t = (bayer2(psp) + 0.5) / 4.0;
		} else {
			t = (bayer4(psp) + 0.5) / 16.0;
		}
		t = mix(t, 0.5, video);
		q = min(floor(c / stepSize + t), maxLevel);
	}

	return expandTo8(q, bits) / 255.0;
}

vec3 fetchTexel(vec2 texel) {
	return texture2D(sampler0, (texel + 0.5) * texelDelta).rgb;
}

// Box-filter the render texels covering one PSP pixel (up to 4x4 taps).
vec3 pspPixelAverage(vec2 psp, vec2 scale) {
	vec2 n = clamp(floor(scale + 0.5), 1.0, 4.0);
	vec3 sum = vec3(0.0);
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			vec2 ij = vec2(float(i), float(j));
			if (ij.x < n.x && ij.y < n.y) {
				sum += fetchTexel(floor(psp * scale + (ij + 0.5) * scale / n));
			}
		}
	}
	return sum / (n.x * n.y);
}

// Modes whose cells are whole PSP pixels; the others work per render texel.
bool nativeCells(float mode) {
	return (mode > 1.5 && mode < 2.5) || mode > 3.5;
}

// Color of one cell before the emulated framebuffer write.
vec3 cellSource(vec2 cell, vec2 scale, float mode) {
	if (mode < 1.5) {
		return fetchTexel(cell);
	}
	if (mode < 2.5) {
		return pspPixelAverage(cell, scale);
	}
	if (mode < 3.5) {
		// Native 480x272 color, dithered per render texel.
		return pspPixelAverage(floor((cell + 0.5) / scale), scale);
	}
	return fetchTexel(floor((cell + 0.5) * scale));
}

// Dither-matrix coordinate of one cell.
vec2 ditherGrid(vec2 cell, vec2 scale, float mode) {
	return mode < 0.5 ? floor((cell + 0.5) / scale) : cell;
}

void main() {
	vec2 tc = v_texcoord0;
	vec2 bufSize = pspBufferSize(dFdx(tc), dFdy(tc));
	vec2 reported = 1.0 / u_texelDelta;
	// Render texels per PSP pixel (2.0 at 2x internal resolution).
	float s = renderScale(reported, bufSize);
	vec2 scale = vec2(s);
	texelDelta = inputTexelDelta(reported, bufSize, s);
	vec2 texSize = 1.0 / texelDelta;

	float mode = u_setting.z;
	bool native = nativeCells(mode);
	vec3 bits = formatBits(u_setting.x);

	vec2 texel = floor(tc * texSize);
	vec2 cell = native ? floor((texel + 0.5) / scale) : texel;
	vec3 src = cellSource(cell, scale, mode);
	vec3 color = pspWritePixel(src, ditherGrid(cell, scale, mode), bits);

	// Gaussian with sigma = radius / 2, in cells, cut off at 3 sigma. Taps (at most 7x7)
	// are spread out for large kernels; below one cell of reach there's nothing to blur.
	// The slider's 0-1 covers radii of 0-1.5 PSP pixels.
	float radius = u_setting.w * 1.5;
	vec2 sigma = radius * 0.5 * (native ? vec2(1.0) : scale);
	vec2 reach = 3.0 * sigma;
	if (max(reach.x, reach.y) >= 1.0) {
		vec2 stride = max(vec2(1.0), reach / 3.0);
		vec3 errorSum = color - src;
		float weightSum = 1.0;
		for (int j = -3; j <= 3; j++) {
			for (int i = -3; i <= 3; i++) {
				vec2 d = floor(vec2(float(i), float(j)) * stride + 0.5);
				if ((i == 0 && j == 0) || abs(d.x) > reach.x || abs(d.y) > reach.y) continue;

				vec2 g = d / max(sigma, vec2(1e-3));
				float w = exp(-0.5 * dot(g, g));
				vec2 n = cell + d;
				vec3 s = cellSource(n, scale, mode);
				errorSum += (pspWritePixel(s, ditherGrid(n, scale, mode), bits) - s) * w;
				weightSum += w;
			}
		}
		color = clamp(src + errorSum / weightSum, 0.0, 1.0);
	}

	gl_FragColor = vec4(color, outputSizeCode());
}
