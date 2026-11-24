// PSP Hardware Dithering, pass 2: pixel-exact scaling of the pass 1 image to the screen.
// Nearest texel, with the boundary blended by the exact area the output pixel covers on
// each side, so dither cells never get smeared at non-integer window sizes and stay
// untouched at integer ones.

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

// Size of one pass 1 texel in texcoords.
vec2 texelDelta;

// When this is the final pass, PPSSPP fills u_texelDelta from the game framebuffer, not from
// pass 1's output (546 texels wide instead of 480 in MGS Peace Walker at 1x), which stretches
// some PSP pixels and squeezes others. Pass 1 writes its real size into alpha, the same in
// every texel, as the render scale plus 64 x the stereo layout, or 255 if it couldn't.
vec2 inputTexelDelta() {
	float code = floor(texture2D(sampler0, v_texcoord0).a * 255.0 + 0.5);
	if (code > 254.5) {
		return u_texelDelta;
	}
	float scale = mod(code, 64.0);
	float stereo = floor(code / 64.0);
	vec2 stack = stereo > 1.5 ? vec2(1.0, 2.0) : (stereo > 0.5 ? vec2(2.0, 1.0) : vec2(1.0));
	return 1.0 / (vec2(480.0, 272.0) * scale * stack);
}

vec3 fetchTexel(vec2 texel) {
	return texture2D(sampler0, (texel + 0.5) * texelDelta).rgb;
}

void main() {
	texelDelta = inputTexelDelta();

	// Position in texels and the size of this output pixel in texels.
	vec2 p = v_texcoord0 / texelDelta;
	vec2 fw = fwidth(p);

	vec2 base = floor(p - 0.5);
	vec2 w = clamp((p - 1.0 - base) / max(fw, vec2(1e-4)) + 0.5, 0.0, 1.0);

	vec3 color = mix(fetchTexel(base), fetchTexel(base + vec2(1.0, 0.0)), w.x);
	if (w.y > 0.0) {
		vec3 bottom = mix(fetchTexel(base + vec2(0.0, 1.0)), fetchTexel(base + vec2(1.0, 1.0)), w.x);
		color = mix(color, bottom, w.y);
	}
	gl_FragColor = vec4(color, 1.0);
}
