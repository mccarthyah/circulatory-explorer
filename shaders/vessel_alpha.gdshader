shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque;

// Anatomical surface shader with a spherical "cutaway" around the camera, so
// that a fly-through camera never ends up staring at the inside of a wall.

uniform vec4 albedo : source_color = vec4(0.78, 0.12, 0.13, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.42;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform vec4 emission_color : source_color = vec4(0.3, 0.02, 0.02, 1.0);
uniform float emission_strength : hint_range(0.0, 4.0) = 0.55;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.45;

uniform vec3 hole_center = vec3(0.0);
uniform float hole_radius = 0.0;
// 1 = mottled tissue, 0 = flat (cheaper; used by the low-detail preset)
uniform float mottle : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;

// cheap trilinear value noise, used to give the surface some organic texture
float hash13(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i + vec3(0.0, 0.0, 0.0)), hash13(i + vec3(1.0, 0.0, 0.0)), f.x),
				   mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
			   mix(mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), f.x),
				   mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (hole_radius > 0.0 && distance(world_pos, hole_center) < hole_radius) {
		discard;
	}
	float shade = 1.0;
	float eshade = 1.0;
	if (mottle > 0.001) {
		float n = value_noise(world_pos * 1.7) * 0.6 + value_noise(world_pos * 6.1) * 0.4;
		shade = mix(1.0, 0.80 + 0.40 * n, mottle);
		eshade = mix(1.0, 0.78 + 0.44 * n, mottle);
	}
	// what we see from inside a vessel is a back face: keep it darker than the
	// outside of the wall so the lumen reads as a tunnel, not a light box
	float inner = FRONT_FACING ? 1.0 : 0.34;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = albedo.rgb * inner * shade;
	ALPHA = albedo.a;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular;
	EMISSION = (emission_color.rgb * emission_strength
			+ emission_color.rgb * rim * rim_strength * 2.0) * inner * eshade;
}
