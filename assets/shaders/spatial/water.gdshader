shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8    // I am unsure how to generalize this.
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;

uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform float timescale = 1.0;

group_uniforms merge_stuff;
uniform float beach_alpha_fadeout = 0.05;
uniform float underwater_tex_border = 4.0;
uniform sampler2D water_color_gradient : source_color,repeat_disable;
uniform sampler2D water_albedo : source_color;
uniform float water_albedo_uv_scale = 0.05;
uniform sampler2D vector_map : hint_default_black, filter_linear;
uniform sampler2D bubble_normal_map : hint_normal, filter_linear;
uniform sampler2D bubble_albedo_map : source_color, filter_linear_mipmap;
uniform sampler2D foam_normal_map : hint_normal, filter_linear;
uniform sampler2D foam_albedo_map : source_color, filter_linear_mipmap_anisotropic;
uniform float foam_uv_scale = 0.05;
uniform sampler2D underwater_albedo_map : source_color;
uniform sampler2D swimthings_albedo_map : source_color;
uniform sampler2D beach_waves_map : source_color, filter_linear;
uniform sampler2D detail_normal_map : hint_normal;
uniform sampler2D water_highlight_map : source_color;
uniform float water_highlight_uv_scale = 0.05;
uniform float depth_fade_distance : hint_range(0.0, 10.0) = 1.0;
uniform float absorbance : hint_range(0.0, 10.0) = 2.0;
uniform vec3 shallow_color : source_color = vec3(0.22, 0.66, 1.0);
uniform vec3 deep_color : source_color = vec3(0.0, 0.25, 0.45);
group_uniforms;

group_uniforms sss_stuff;
uniform float sss_strength = 7.0;
uniform float sss_1:hint_range(-1.0, 1.0, 0.01) = 0.65;
uniform float sss_2:hint_range(-1.0, 1.0, 0.01) = 0.7;
uniform float sss_3:hint_range(-1.0, 1.0, 0.01) = 0.5;
uniform float sss_4:hint_range(-1.0, 1.0, 0.01) = 1.0;
group_uniforms;

uniform float height_alpha_mod = .2;
uniform float height_alpha_pow = 2.0;



group_uniforms backlighting;
uniform float backlight_dot_adj:hint_range(-1.0, 1.0, 0.01) = 0.65;
uniform float backlight_dot_adj2:hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float backlight_stren = 1.0;
uniform float backlight_pt_stren = 1.0;
uniform float backlight_refract = 1.0;
uniform vec3 backlight_color:source_color;
uniform vec3 backlight_filter:source_color;
uniform float backlight_dist_modifier = 20.0;
uniform float backlight_dist_modifier_min = 0.3;
uniform float backlight_dist_modifier_max = 2.0;
uniform float backlight_h_mul = 0.3;
uniform float backlight_h_add = 2.0;
uniform float backlight_pow = 2.0;
uniform float backlight_dir_affect_min = 0.1;
uniform sampler2D backlight_col_gradient:source_color;
uniform float backlight_grad_pow = 1.0;
uniform float backlight_grad_mul = 1.0;
uniform float backlight_grad_add = 0.0;
group_uniforms;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
global uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.
group_uniforms;
varying float wave_height;
//varying float foam_factor;
varying float fresnel;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
//varying vec3 idk_normal;
//varying vec3 world_vertex;


vec3 mtf(mat4 a, vec3 b){
	return (a * vec4(b,1.0)).xyz;
}
vec3 mtf2(mat4 a, vec3 b){
	return (a * vec4(b,0.0)).xyz;
}
void vertex() {
	
	//world_vertex =(MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
	
	//vec3 cam_pos = (inverse(PROJECTION_MATRIX)  * vec4(CAMERA_POSITION_WORLD,1.0)).xyz;
	
	UV = VERTEX.xz;//VERTEX.xz;
	float distance_factor = min(exp(-(length(VERTEX.xz - CAMERA_POSITION_WORLD.xz) - 150.0)*0.007), 1.0); // Displacement amonut falls off after 150m.
	//float distance_factor = min(exp(-(length(VERTEX.xz - CAMERA_POSITION_WORLD.xz) - 150.0)*0.007), 1.0); // Displacement amonut falls off after 150m.
	
	//TODO: combined displacement map for world stuff, since it moves in x-y plane
	// Read displacements from displacement maps.
	vec3 displacement = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		displacement += texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z;
	}
	VERTEX += displacement * distance_factor;
	wave_height = displacement.y* distance_factor;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;
	
	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;
	
	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
    return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y); 
}

vec3 WorldPosFromDepth(vec2 screenUV, mat4 inv_proj, mat4 inv_view) {
	float depth = texture(DEPTH_TEXTURE,screenUV).x;
    float z = depth * 2.0 - 1.0;

    vec4 clipSpacePosition = vec4(screenUV * 2.0 - 1.0, z, 1.0);
    vec4 viewSpacePosition = inv_proj * clipSpacePosition;

    // Perspective division
    viewSpacePosition /= viewSpacePosition.w;

    vec4 worldSpacePosition = inv_view * viewSpacePosition;

    return worldSpacePosition.xyz;
}
vec3 screen(vec3 base, vec3 blend){
	return 1.0 - (1.0 - base) * (1.0 - blend);
}

void fragment() {
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz);
	// Read foam and normal information from normal maps.
	vec3 gradient = vec3(0);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV*scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
		// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
		// This is dependent on the tile size as well as displacement/normal map resolution.
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm*0.1)).xyw * vec3(scales.ww, 1.0);
	}
	
	float foam_factor = smoothstep(0.0, 1.0, gradient.z*0.75) * exp(-dist*0.0075);
	
	gradient *= mix(0.015, normal_strength, exp(-dist*0.0175)); // Blend normal with terrain normal as distance increases.
	//idk_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	vec3 normal_output = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
	
	//float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r; // LOOSING SS-REFLECTIONS
		
	//// DEPTH REPROJECTION FROM CAMERA Z to Z Axis
	//depth = depth;// * 2.0 - 1.0;
	////depth = PROJECTION_MATRIX[3][2] / (depth + PROJECTION_MATRIX[2][2]); // Camera Z Depth to World Space Z
	//depth = PROJECTION_MATRIX[3][2] / (depth + PROJECTION_MATRIX[2][2]); // Camera Z Depth to World Space Z
	//depth =  depth + VERTEX.z;
	//// NORMAL APPLIED TO DEPTH AND READ FROM BUFFER AGAIN (DISTORTED Z-DEPTH)
	//vec2 duv = SCREEN_UV + ((normal_output.xy - vec2(0.5, 0.5)) * clamp(depth * 0.2, 0.0, 0.1) );
	//depth = texture(DEPTH_TEXTURE, duv).r;
	//depth = depth * 2.0 - 1.0;
	//depth = PROJECTION_MATRIX[3][2] / (depth + PROJECTION_MATRIX[2][2]); // Camera Z Depth to World Space Z
	//vec3 wp = WorldPosFromDepth(duv,INV_PROJECTION_MATRIX,INV_VIEW_MATRIX);
	////depth = depth + VERTEX.z;
	//float alpha_output = smoothstep(depth, 0.00, beach_alpha_fadeout);
	//=====================================
	//SCREEN
	//float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r; // LOOSING SS-REFLECTIONS
	//// DEPTH REPROJECTION FROM NDC Z to VIEW Z Axis
	//depth = PROJECTION_MATRIX[3][2] / (depth - PROJECTION_MATRIX[2][2]); // NDC Z Depth to VIEW Space Z
	//depth = depth + VERTEX.z;
	//// NORMAL APPLIED TO DEPTH AND READ FROM BUFFER AGAIN (DISTORTED Z-DEPTH)
	//depth = texture(DEPTH_TEXTURE, SCREEN_UV + (normal_output.xy - 0.5) * clamp(depth * 0.2, 0.0, 0.1) ).r;
	//depth = PROJECTION_MATRIX[3][2] / (depth - PROJECTION_MATRIX[2][2]); // NDC Z Depth to VIEW Space Z
	//depth = depth + VERTEX.z;
	//float depth_mask = clamp(depth * underwater_tex_border, 0.0, 1.0);
	//vec3 water_gradient = texture(water_color_local, vec2(0.0, depth * 1.0)).xyz;
	//=====================================
	
	vec3 foam_tex_col = texture(foam_albedo_map,UV*foam_uv_scale).rgb;
	//foam_factor += 1.0-foam_tex_col.r;
	//vec3 albedo_output = mix(water_color.rgb, foam_color.rgb, foam_factor);
	//water_color.rgb;//
	vec3 water_col = water_color.rgb;
	
	vec3 albedo_output = mix(water_col.rgb, screen(water_col.rgb,foam_tex_col), foam_factor);
	vec3 screen = texture(SCREEN_TEXTURE, SCREEN_UV).xyz; // LOOSING SS-REFLECTIONS
	//albedo_output = mix(screen, albedo_output, depth_mask);
	
	NORMAL = clamp(normal_output, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0));
	//NORMAL = clamp(normal_output, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0));
	
	//=============================
	//float depth2 = texture(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
  	//vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth2);
	//vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	//float depth_texture_y = world.y / world.w;
	//float vertex_y = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	//float vertical_depth = vertex_y - depth_texture_y;
	//
	//// Changes the color of geometry behind it as the water gets deeper
	//float depth_fade_blend = exp(-vertical_depth / depth_fade_distance);
	//depth_fade_blend = clamp(depth_fade_blend, 0.0, 1.0);
	//
	//// Makes the water more transparent as it gets more shallow
	//float alpha_blend = -vertical_depth * absorbance;
	//alpha_blend = clamp(1.0 - exp(alpha_blend), 0.0, 1.0);
	//vec3 color_out = mix(deep_color, albedo_output, depth_fade_blend);
	//if((inverse(VIEW_MATRIX) * vec4(normalize(VIEW),1.0)).y > 0.0){
		//color_out = albedo_output;
	//}
	//color_out = screen(color_out, foam);
	//=============================
	
	//vec3 underneath_color = texture(SCREEN_TEXTURE,SCREEN_UV).rgb;
	//NORMAL_MAP = vec3(0.5,0.5,0.5);
	//ALBEDO = mtf(INV_VIEW_MATRIX, NORMAL_MAP);// 
	ALBEDO = albedo_output;// vec3(texture(DEPTH_TEXTURE, duv).r);// albedo_output; 
	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);
	ROUGHNESS = (1.0 - fresnel) * foam_factor + 0.4; // Roughness is proportional to foam/fog amount and fresnel.
	//ROUGHNESS = 0.08;
	SPECULAR = 0.6;
	//METALLIC =  clamp((1.0 - fresnel) * foam_factor + 0.4,0.0,1.0);
	//ALPHA = 0.8;// clamp(pow(1.0-wave_height*height_alpha_mod,height_alpha_pow),0.0,1.0);
	//BACKLIGHT = backlight_color;//*FRAGCOORD.w * backlight_dist;
	//vec3 bl_col = texture(backlight_col_gradient, vec2(clamp(pow((wave_height+backlight_grad_add)*backlight_grad_mul,backlight_pow),0.0,1.0),0.0)).rgb;
	BACKLIGHT = backlight_color * clamp(FRAGCOORD.w * backlight_dist_modifier,backlight_dist_modifier_min,backlight_dist_modifier_max);// clamp(backlight_dist_modifier, backlight_dist_modifier_min,1.0);
	//EMISSION = BACKLIGHT/10.0;
	//BACKLIGHT = backlight_color * smoothstep(backlight_dist_modifier_min,backlight_dist_modifier_max,FRAGCOORD.w * backlight_dist_modifier);// clamp(backlight_dist_modifier, backlight_dist_modifier_min,1.0);
	//ALBEDO = vec3(1.0);
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta)); // Approximate: 1.0 / (alpha * tan(acos(cos_theta)))
	float a_sq = a*a;
	return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha*alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d*d);
}

//void light() {
	//vec3 halfway = normalize(LIGHT + VIEW);
	//float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
	//float dot_nv = max(dot(NORMAL, VIEW), 2e-5);
//
	//// --- SPECULAR ---
	//float light_mask = smith_masking_shadowing(roughness, dot_nv);
	//float view_mask = smith_masking_shadowing(roughness, dot_nl);
	//float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
	//float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
	//SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;
//
	//// --- DIFFUSE ---
	//const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
	//float sss_height = 1.0*max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
	//float sss_near = 0.5*pow(dot_nv, 2.0);
	//float lambertian = 0.5*dot_nl;
	//DIFFUSE_LIGHT += mix((sss_height + sss_near) * sss_modifier / (1.0 + light_mask) + lambertian, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
	//float lambert = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	//float viewDot = clamp(dot(VIEW,NORMAL),0.0,1.0);
	//float viewDot2 = clamp(dot(LIGHT,NORMAL*vec3(1.0,.3,1.0)) * backlight_dot_adj2,0.0,1.0);
	//vec3 blc =  (((LIGHT_COLOR*4.0)+ BACKLIGHT)/2.0);
	////vec3 blc =  (((LIGHT_COLOR)+ BACKLIGHT)/2.0);
	////vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	////vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	//DIFFUSE_LIGHT += backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(dot(-NORMAL, LIGHT)+backlight_dot_adj, 0.0, 1.0)* ATTENUATION)* blc;
//}
//
//void light() {
	//
	//
	//float viewDot = clamp(dot(VIEW,-NORMAL),0.0,1.0);
	////float viewDot2 = clamp(dot(NORMAL,VIEW) * backlight_dot_adj2,0.0,1.0);
	////float viewDot2 = clamp(dot(LIGHT*vec3(1.0,-1.0,1.0),VIEW) * backlight_dot_adj2,0.0,1.0);
	//float viewDot2 = clamp(dot(LIGHT,-NORMAL*vec3(1.0,.3,1.0)) * backlight_dot_adj2,0.0,1.0);
	////float viewDot2 = 1.0;// clamp(dot(reflect(LIGHT,NORMAL),-VIEW) * backlight_dot_adj2,0.0,1.0);
	////float viewDot2 = clamp(dot(reflect(LIGHT,-NORMAL*vec3(1.0,-1.0,1.0)),refract(VIEW,-NORMAL.xyz,backlight_refract)) * backlight_dot_adj2,0.0,1.0);
	////float viewDot2 = clamp(dot(LIGHT,refract(VIEW,-NORMAL.xyz,backlight_refract)) * backlight_dot_adj2,0.0,1.0);
	////(INV_PROJECTION_MATRIX * vec4(0.0,1.0,0.0,1.0)).xyz
	//// LAMBER DIFFUSE LIGHTING
	//float pi = 3.14159265358979323846;
	//float water_highlight_mask_1 = texture(water_highlight_map, fract( UV - (MODEL_MATRIX[3].xz * 0.25) + (TIME * timescale) * 0.051031 ) ).x;
	//float water_highlight_mask_2 = texture(water_highlight_map, fract( UV - (MODEL_MATRIX[3].xz * 0.25) + (TIME * timescale) * -0.047854) * 2.0 ).x;
	//
	//// SUBSURFACE SCATTERING
	//float sss = clamp( smoothstep(sss_1,sss_2, dot(-NORMAL , VIEW) * 0.5 + 0.5 ) * smoothstep(0.5, 1.0, (dot(-LIGHT, VIEW) * 0.5 + 0.5) ) * ( dot (-INV_VIEW_MATRIX [2].xyz, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5), 0.0, 1.0) * sss_strength;
		//
	//float lambert = clamp(dot(-NORMAL, LIGHT), 0.0, 1.0);
	//float spec = clamp( pow( dot( reflect(LIGHT, -NORMAL), -VIEW), 1000.0), 0.0, 1.0) * 2.0;
	//float spec_glare = clamp( pow( dot( reflect(LIGHT, -NORMAL), -VIEW), 100.0), 0.0, 1.0) * smoothstep(0.0, 0.1, water_highlight_mask_1 * water_highlight_mask_2) * 30.0;
	//
	////DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / pi) * lambert;
	////DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / pi) * sss;
	////DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (spec + spec_glare);
	//
	////dot(NORMAL * vec3(1.0,-1.0,1.0), VIEW)
	////DIFFUSE_LIGHT +=  smoothstep(sss_3,sss_4,clamp(dot(-NORMAL, LIGHT), 0.0, 1.0))* (BACKLIGHT/3000.0)* ATTENUATION;
	//vec3 blc = BACKLIGHT*4.0;// (((LIGHT_COLOR*1.0)+ BACKLIGHT)/2.0);
	////vec3 blc =  (((LIGHT_COLOR*4.0)+ BACKLIGHT)/2.0);
	////vec3 blc =  (((LIGHT_COLOR)+ BACKLIGHT)/2.0);
	////vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	////vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	//DIFFUSE_LIGHT += backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(dot(NORMAL, LIGHT)+backlight_dot_adj, 0.0, 1.0)* ATTENUATION)* blc;
	////DIFFUSE_LIGHT = NORMAL;
//}

void light() {
	
	//vec3 world_light = normalize((INV_VIEW_MATRIX * vec4(LIGHT,0.0)).xyz);
	//vec3 world_norm = normalize((INV_VIEW_MATRIX * vec4(NORMAL,0.0)).xyz);
	//vec3 world_view = normalize((INV_VIEW_MATRIX * vec4(VIEW,0.0)).xyz);
	
	vec3 my_view = VIEW;//mtf2(INV_VIEW_MATRIX,VIEW);

	//vec3 my_norm = vec3(NORMAL.x,-NORMAL.y,NORMAL.z);
	//vec3 reflect_vec = normalize(-reflect(world_view,world_norm));
	//float reflect_dot = dot(reflect_vec,-world_light);
	vec3 my_norm =  vec3(NORMAL.x,NORMAL.y,NORMAL.z);
	
	vec3 my_norm_flipped = vec3(NORMAL.x,-NORMAL.y,NORMAL.z);
	//vec3 reflect_vec = normalize(-reflect(VIEW,NORMAL));
	//float reflect_dot = dot(reflect_vec,-LIGHT);
	
	//float reflect_dot = dot(normalize(reflect(world_view,world_norm)),vec3(LIGHT.x,LIGHT.y,LIGHT.z));
	
	//float viewDot = clamp(dot(my_view,my_norm),0.0,1.0);
	//float viewDot2 = clamp(dot(LIGHT,my_norm*vec3(1.0,.3,1.0)) * backlight_dot_adj2,0.0,1.0);
	//float viewDot3 = clamp(smoothstep(sss_1,sss_2, dot(LIGHT,my_norm*vec3(1.0,.3,1.0)) * backlight_dot_adj2),0.0,1.0);
	
	// LAMBER DIFFUSE LIGHTING
	const float pi = 3.14159265358979323846;
	float water_highlight_mask_1 = texture(water_highlight_map, fract( (UV* water_highlight_uv_scale) - (MODEL_MATRIX[3].xz * 0.25) + (TIME * timescale) * 0.051031 ) ).x;
	float water_highlight_mask_2 = texture(water_highlight_map, fract( (UV* water_highlight_uv_scale ) - (MODEL_MATRIX[3].xz * 0.25) + (TIME * timescale) * -0.047854 ) * 2.0 ).x;
	//float water_highlight_mask_1 = texture(water_highlight_map, (UV* water_highlight_uv_scale) + (TIME * timescale) * 0.051031 ).x;
	//float water_highlight_mask_2 = texture(water_highlight_map, (UV* water_highlight_uv_scale ) + (TIME * timescale) * -0.047854  * 2.0 ).x;

	// SUBSURFACE SCATTERING
	float sss = clamp( smoothstep(sss_1,sss_2, dot(my_norm , my_view) * 0.5 + 0.5 ) * smoothstep(0.5, 1.0, (dot(-LIGHT, my_view) * 0.5 + 0.5) ) * ( dot (-INV_VIEW_MATRIX [2].xyz, vec3(0.0, 1.0, 0.0)) * 0.5 + 0.5), 0.0, 1.0) * sss_strength;
		
	float lambert = clamp(dot(my_norm, LIGHT), 0.0, 1.0);
	float spec = clamp( pow( dot( reflect(LIGHT, my_norm),-my_view), 1000.0), 0.0, 1.0) * 2.0;
	float spec_glare = clamp( pow( dot( reflect(LIGHT, my_norm), -my_view), 100.0), 0.0, 1.0) * smoothstep(0.0, 0.1, water_highlight_mask_1 * water_highlight_mask_2) * 30.0;
	
	DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / pi) * lambert;
	DIFFUSE_LIGHT += (LIGHT_COLOR * ALBEDO * ATTENUATION / pi) * sss;
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (spec + spec_glare);
	
	//dot(NORMAL * vec3(1.0,-1.0,1.0), VIEW)
	//DIFFUSE_LIGHT +=  smoothstep(sss_3,sss_4,clamp(dot(-NORMAL, LIGHT), 0.0, 1.0))* (BACKLIGHT/3000.0)* ATTENUATION;
	
	//vec3 blc =  (((LIGHT_COLOR)+ BACKLIGHT)/2.0);
	//vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	//vec3 blc =  LIGHT_COLOR * backlight_filter;//* vec3(0.2,0.5,0.9);
	//DIFFUSE_LIGHT += BACKLIGHT*backlight_stren * ATTENUATION;// backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(dot(-my_norm, LIGHT)+backlight_dot_adj, 0.0, 1.0)* ATTENUATION)* blc;
	//DIFFUSE_LIGHT += backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(dot(-my_norm, LIGHT)+backlight_dot_adj, 0.0, 1.0)* ATTENUATION)* blc;
	//DIFFUSE_LIGHT += backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(dot(-my_norm, LIGHT)+backlight_dot_adj, 0.0, 1.0))* blc * ATTENUATION;
	//DIFFUSE_LIGHT += backlight_stren * viewDot2 * viewDot *  smoothstep(sss_3,sss_4,(1.0-lambert) *clamp(reflect_dot+backlight_dot_adj, 0.0, 1.0))* blc * ATTENUATION;
	
	// smoothstep(sss_1,sss_2, clamp(dot(my_view,-normalize(LIGHT)),0.0,1.0));
	//if(normalize(VIEW).y > -0.0 && normalize(VIEW).y < 0.2){
		//vdt = 1.0;
	//}
	if(LIGHT_IS_DIRECTIONAL){
		float md =clamp(dot(-NORMAL,LIGHT) + backlight_dot_adj,0.0,1.0);
		//float md =clamp(dot(-normalize(vec3(NORMAL.x,0.0,NORMAL.z)),normalize(vec3(LIGHT.x,0.0,LIGHT.z))) + backlight_dot_adj,0.0,1.0);
		
		float vdt = clamp(dot(my_view,-normalize(LIGHT))-backlight_dot_adj2,0.0,1.0);//0.0;
		//float vdt = clamp(dot(normalize(vec3(my_view.x,0.0,my_view.z)),-normalize(vec3(LIGHT.x,0.0,LIGHT.z)))-backlight_dot_adj2,0.0,1.0);//0.0;
		float view_light_dir_effect = (clamp(vdt,backlight_dir_affect_min,1.0));
		
		vec3 blc =  (LIGHT_COLOR.r+LIGHT_COLOR.g+LIGHT_COLOR.b)/3.0  * BACKLIGHT;// BACKLIGHT;// (((LIGHT_COLOR*1.0)+ BACKLIGHT)/2.0);
		//blc =  (((LIGHT_COLOR*4.0)+ BACKLIGHT)/2.0);
		//blc =  (LIGHT_COLOR.r+LIGHT_COLOR.g+LIGHT_COLOR.b)/3.0  * BACKLIGHT;
		
		DIFFUSE_LIGHT += backlight_stren * clamp(pow((wave_height+backlight_h_add)*backlight_h_mul,backlight_pow),0.0,1.0) * blc * ATTENUATION * md * view_light_dir_effect;// * md * ATTENUATION;
	}
	else{
		DIFFUSE_LIGHT += backlight_pt_stren * (((LIGHT_COLOR)+ BACKLIGHT*4.0)/5.0) * ATTENUATION;// * md * ATTENUATION;
		
	}
	//DIFFUSE_LIGHT = NORMAL;
}