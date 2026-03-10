#include "ReShade.fxh"
#include "ReShadeUI.fxh"

namespace Glamarye_Fast_Effects
{


// This is your quality/speed trade-off. Minimum 2, maximum 16. 4, 6 and 8 are good options as they have special optimized code.
// This was a GUI slider, but it caused problems with DirectX 9 games failing to compile it. Have to use pre-processor.
#ifndef FAST_AO_POINTS
	#define FAST_AO_POINTS 6
#endif


// This is the brightness in nits of diffuse white (HDR can go brighter in lights and reflections). If you have a similar setting in game then match this to it for maximum accuracy.
// If unshadowed areas in the "show AO shade" debug mode is much darker then the overall game then you maybe need to increase this.
// If the game's 16-bit output is actually in nits, not scRGB, then set this to 1 (I hear some Epic games may do this but have not seen it).

/* Based on ITU specification BT.2408 our default is 203.
   DirectX documentation talks about 80 as the whitelevel - which originally was the standard.
   However in practice SDR is displayed brighter than 80 nits on modern screens and so is HDR content to avoid appearing darker than SDR content - BT.2408 reflects that.
   If you have configured WHITELEVEL in your game then this should be set to match it.
*/
#ifndef HDR_WHITELEVEL
	#define HDR_WHITELEVEL 203
#endif



// New in ReShade 5.1: Added "BUFFER_COLOR_SPACE" pre-processor definition which contains the color space type for presentation (0 = unknown, 1 = sRGB, 2 = scRGB, 3 = HDR10 ST2084, 4 = HDR10 HLG).


#ifndef OVERRIDE_COLOR_SPACE
	#define OVERRIDE_COLOR_SPACE 0
#endif

#if OVERRIDE_COLOR_SPACE > 0
	#undef BUFFER_COLOR_SPACE
	#define BUFFER_COLOR_SPACE OVERRIDE_COLOR_SPACE
#endif

#if BUFFER_COLOR_SPACE > 0
#else
	#if BUFFER_COLOR_BIT_DEPTH == 8
		#undef BUFFER_COLOR_SPACE
		#define BUFFER_COLOR_SPACE 1
	#elif BUFFER_COLOR_BIT_DEPTH == 16
		#undef BUFFER_COLOR_SPACE
		#define BUFFER_COLOR_SPACE 2
	#elif __RENDERER__ < 0xb000
		// Version of DirectX that only supports SDR.
		#undef BUFFER_COLOR_SPACE
		#define BUFFER_COLOR_SPACE 1
	#endif
#endif

#if BUFFER_COLOR_BIT_DEPTH == 10 &&  __RENDERER__ >= 0xb000 && __RESHADE__ <= 50100 && OVERRIDE_COLOR_SPACE == 0
				// Reshade hasn't helped us.
		uniform int select_color_space
		<
			ui_category = "Color Space";
			ui_type = "combo";
			ui_label = "color space (CHECK THIS!)";
			ui_tooltip = "When HDR (high-dynamic range) arrived it added several new ways of encoding brightness. \n\nAs you are running an older version of ReShade and the game has 10-bit output you need to check and set this manually; Upgrade to ReShade 5.2 for working autodetection. \n\nIs the game running with HDR? Recommendations:\n\n * If your game and screen are in HDR mode then set to HDR Perceptual Quantizer.\n * If not then set it to SDR sRGB. \n\nIf set incorrectly some effects will look bad (e.g. strong brightness/color changes in effects that should be more subtle.)\n\nIf in doubt, pick the option that where the images changes the least when you enable Glamayre.";

			ui_items = "SDR sRGB (PC standard for non-HDR screens)\0"
					   "HDR Perceptual Quantizer (SMTPE ST2084)\0";
				> = 0;
	#define GLAMAYRE_COLOR_SPACE (select_color_space*2+1)
#else
	uniform int show_color_space
		<
			ui_category = "Color Space";
			ui_type = "combo";
			ui_label = "color space";
			ui_tooltip = "When HDR (high-dynamic range) arrived it added several new ways of encoding brightness. \n\nReShade or Glamayre has detected which the game is using. To override that set the OVERRIDE_COLOR_SPACE pre-processor definition. \n\n1 = sRGB (standard dynamic range), 2 = scRGB (linear), 3 = Perceptual Quantizer (SMPTE ST 2084), 4 = hybrid log–gamma (ARIB STD-B67).\0";

			#if BUFFER_COLOR_SPACE == 1
				ui_items = "1 sRGB (autodetected)\0";
			#elif BUFFER_COLOR_SPACE == 2
				ui_items = "2 scRGB (autodetected)\0";
			#elif BUFFER_COLOR_SPACE == 3
				ui_items = "3 Perceptual quantizer (autodetected)\0";
			#elif BUFFER_COLOR_SPACE == 4
				ui_items = "4 hybrid log–gamma (autodetected)\0";
			#else
				ui_items = "Unknown! (using sRGB)\0";
			#endif
		> = 0;
	#define GLAMAYRE_COLOR_SPACE BUFFER_COLOR_SPACE
#endif


uniform int fast_color_space_conversion <
		ui_category = "Color Space";
		ui_type = "combo";
		ui_label = "Transfer Function precision";
		ui_items = "Accurate\0"
				   "Fast Approximation\0"
				   "Hardware sRGB\0";
		ui_tooltip = "Correct color space conversions (especially PQ) can be slow. A fast approximation is okay because we apply the conversion one way, apply our effects, then apply the opposite conversion - so inaccuracies in fast mode mostly cancel out.\n\nMost effects don't need perfect linear color, just something pretty close.\n\nHardware sRGB is only available for 8-bit SDR content.";
	> = 
#if BUFFER_COLOR_BIT_DEPTH > 8 || BUFFER_COLOR_SPACE > 1
	1; // Default to fast approximation for HDR
#else
	2; // Default to hardware sRGB for 8-bit SDR
#endif

// You may also choose fast or accurate mode. A fast approximation is okay because we apply the conversion one way, apply our effects, then apply the opposite conversion - so inaccuracies in fast mode mostly cancel out. Glamayre doesn't need perfect linear color, just something pretty close.

uniform bool fxaa_enabled <
    ui_category = "Enabled Effects";
    ui_label = "Fast FXAA";
    ui_tooltip = "Fullscreen approximate anti-aliasing. Fixes jagged edges. \n\nRecommendation: use with sharpen too, otherwise it can blur details slightly.";
    ui_type = "radio";
> = true;

uniform bool sharp_enabled <
    ui_category = "Enabled Effects";
    ui_label = "Intelligent Sharpen";
    ui_tooltip = "Sharpens image, but working with FXAA and depth of field instead of fighting them. It darkens pixels more than it brightens them; this looks more realistic.";
    ui_type = "radio";
> = true;


uniform bool ao_enabled <
    ui_category = "Enabled Effects";
    ui_label = "Fast Ambient Occlusion (AO) (requires depth buffer)";
    ui_tooltip = "Ambient occlusion shades places that are surrounded by points closer to the camera. It's an approximation of the reduced ambient light reaching occluded areas and concave shapes (e.g. under grass and in corners.)\n\nFor quality adjustment, set pre-processor definition FAST_AO_POINTS. Higher is better quality but slower. Valid range: 2-16. Recommended: 4, 6 or 8 as these have optimized fast code paths.";
    ui_type = "radio";
> = true;


uniform bool dof_enabled <
    ui_category = "Enabled Effects";
    ui_label = "Subtle Depth of field (DOF) (requires depth buffer)";
    ui_tooltip = "Softens distant objects subtly, as if slightly out of focus.";
    ui_type = "radio";
> = true;

uniform bool depth_detect <
    ui_category = "Enabled Effects";
    ui_label = "Detect menus & videos (requires depth buffer)";
    ui_tooltip = "Skip all processing if depth value is 0 (per pixel). Sometimes menus use depth 1 - in that case use Detect Sky option instead. Full-screen videos and 2D menus do not need anti-aliasing nor sharpening, and may look worse with them.\n\nOnly enable if depth buffer always available in gameplay!";
    ui_type = "radio";
> = false;

uniform bool sky_detect <
    ui_category = "Enabled Effects";
    ui_label = "Detect sky (requires depth buffer)";
    ui_tooltip = "Skip all processing if depth value is 1 (per pixel). Background sky images might not need anti-aliasing nor sharpening, and may look worse with them.\n\nOnly enable if depth buffer always available in gameplay!";
    ui_type = "radio";
> = false;


//////////////////////////////////////

uniform float sharp_strength < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Effects Intensity";
	ui_min = 0; ui_max = 2; ui_step = .05;
	ui_tooltip = "For high values I suggest depth of field too. Values > 1 only recommended if you can't see individual pixels (i.e. high resolutions on small or far away screens.)";
	ui_label = "Sharpen strength";
> = 0.75;

uniform float ao_strength < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Effects Intensity";
	ui_min = 0.0; ui_max = 1.0; ui_step = .05;
	ui_tooltip = "Ambient Occlusion. Higher mean deeper shade in concave areas.\n\nTip: if increasing AO strength don't set AO Quality to Performance, or you might notice some imperfections.";
	ui_label = "AO strength";
> = 0.6;


uniform float ao_shine_strength < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Effects Intensity";
	ui_min = 0.0; ui_max = 1; ui_step = .05;
    ui_label = "AO shine";
    ui_tooltip = "Normally AO just adds shade; with this it also brightens convex shapes. \n\nMaybe not realistic, but it prevents the image overall becoming too dark, makes it more vivid, and makes some corners clearer.";
> = 0.3;

uniform float dof_strength < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Effects Intensity";
	ui_min = 0; ui_max = 5; ui_step = .05;
	ui_tooltip = "Depth of field. Applies subtle smoothing to distant objects. It's a small effect (1 pixel radius).\n\nAt the default it more-or-less cancels out sharpening, no more.";
	ui_label = "DOF blur";
> = 0.3;

////////////////////////////////////////////////

uniform float gi_strength < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0.0; ui_max = 10.0; ui_step = .05;
    ui_label = "Fake GI lighting strength";
    ui_tooltip = "Fake Global Illumination wide-area effect. Every pixel gets some light added from the surrounding area of the image.\n\nUsually safe to increase, except in games with unusually bright colors.";
> = 0.5;

uniform float gi_saturation < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0.0; ui_max = 1.0; ui_step = .05;
    ui_label = "Fake GI saturation";
    ui_tooltip = "Fake Global Illumination saturation boost. \n\nThis increases color change, especially in areas of similar brightness. \n\nDecrease this if colors are too saturated or all too similar. Increase for more noticeable indirect light color bounce.";
> = 0.5;

uniform float gi_contrast < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0; ui_max = 1.5; ui_step = 0.01;
	ui_tooltip = "Increases contrast relative to average light in surrounding area. This makes differences between nearby areas clearer. \n\nHowever, too much contrast looks less realistic and may make near black or near white areas less clear.";
	ui_label = "Adaptive contrast enhancement";
> = 0.25;

uniform bool gi_use_depth <
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
    ui_label = "Enable Fake GI effects that require depth (below)";
	ui_tooltip = "If you don't have depth buffer data, or if you don't want the full effect then 2D mode may be faster. \n\nWith depth enabled, it adds big AO, improved local AO with local bounce light, and better direction for lighting.";
> = true;

uniform float gi_ao_strength < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0; ui_max = 1; ui_step = .05;
	ui_tooltip = "Large scale ambient occlusion. Higher = darker shadows. \n\nA big area effect providing subtle shading of enclosed spaces, which would receive less ambient light. \n\nIt is a fast but very approximate. It is subtle and smooth so it's imperfections are not obvious nor annoying. \n\nUse in combination with normal ambient occlusion, not instead of it.";
	ui_label = "Fake GI big AO strength (requires depth)";
> = .5;

uniform float gi_local_ao_strength < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0; ui_max = 1; ui_step = .05;
	ui_tooltip = "Fake GI provides additional ambient occlusion, subtly enhancing Fast Ambient Occlusion and bounce lighting, at very little cost. \n\nThis Higher = darker shadows. \n\nThis would have visible artifacts at high strength; therefore maximum shade added is very small. Use in combination with normal ambient occlusion, not instead of it.";
	ui_label = "Fake GI local AO strength (requires depth)";
> = .75;

uniform float bounce_multiplier < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0.0; ui_max = 2.0; ui_step = .05;
    ui_label = "Fake GI local bounce strength (requires depth)";
    ui_tooltip = "It uses local depth and color information to approximate short-range bounced light. \n\nIt only affects areas made darker by ambient occlusion. A bright red pillar next to a white wall will make the wall a bit red, but how red?";
> = 1;


uniform float gi_shape < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
	ui_min = 0; ui_max = .2; ui_step = .01;
	ui_tooltip = "Fake global illumination uses a very blurred version of the image to collect approximate light from a wide area around each pixel. \n\nIf depth is available, it adjusts the offset based on the angle of the local surface. This makes it better pick up color from facing surfaces, but if set too big it may miss nearby surfaces in favor of further ones. \n\nThe value is the maximum offset, as a fraction of screen size.";
	ui_label = "Fake GI offset";
> = .05;

uniform bool gi_dof_safe_mode <
	ui_category = "Fake Global Illumination (with_Fake_GI version only)";
    ui_label = "Cinematic DOF safe mode";
	ui_tooltip = "The depth of field effect (out of focus background) is now common in games and sometimes cannot be disabled. It interacts badly with AO and GI effects using depth. Enabling this tweaks effects to use a blurred area depth instead of the depth at every pixel, which makes Fake GI depth effects usable in such games.";
> = false;

////////////////////////////////////////////////////////


uniform int debug_mode <
    ui_category = "Advanced Tuning and Configuration";
	ui_type = "combo";
    ui_label = "Debug mode";
    ui_items = "Normal output\0"
	           "Debug: show FXAA edges\0"
			   "Debug: show AO shade & bounce\0"
	           "Debug: show depth buffer\0"
			   "Debug: show depth and edges\0"
			   "Debug: show Fake GI area light\0"
			   ;
	ui_tooltip = "Handy when tuning ambient occlusion settings.";
> = 0;



uniform bool ao_big_dither <
	ui_category = "Advanced Tuning and Configuration";
	ui_tooltip = "Ambient occlusion dither.\n\nDithering means adjacent pixels shade is calculated using different nearby depth samples. If you look closely you may see patterns of alternating light/dark pixels.\n\nIf checked, AO uses an 8 pixel dither pattern; otherwise it uses a 2 pixel pattern.\n\nFrom a distance, bigger dither gives better shadow shapes overall; However, you will see annoying repeating patterns up close.\n\nRecommendation: turn on if you have a high enough screen resolution and far enough distance from your screen that you cannot make out individual pixels by eye.\n\nThe performance is about the same either way.";
	ui_label = "AO bigger dither";
> = false;


uniform float reduce_ao_in_light_areas < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Advanced Tuning and Configuration";
    ui_label = "Reduce AO in bright areas";
	ui_min = 0.0; ui_max = 4; ui_step = 0.1;
    ui_tooltip = "Do not shade very light areas. Helps prevent unwanted shadows in bright transparent effects like smoke and fire, but also reduces them in solid white objects. Increase if you see shadows in white smoke, decrease for more shade on light objects. Doesn't help with dark smoke.";
> = 1;

uniform float ao_fog_fix < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Advanced Tuning and Configuration";
	ui_category_closed=true;
	ui_min = 0.0; ui_max = 2; ui_step = .05;
    ui_label = "AO max distance";
    ui_tooltip = "The ambient occlusion effect fades until it is zero at this distance. Helps to avoid artifacts if the game uses fog or haze. If you see deep shadows in the clouds then reduce this. If the game has long, clear views then increase it.";
> = .5;

uniform float gi_max_distance < __UNIFORM_SLIDER_FLOAT1
    ui_category = "Advanced Tuning and Configuration";
	ui_category_closed=true;
	ui_min = 0.0; ui_max = 1; ui_step = .05;
    ui_label = "Fake GI max distance";
    ui_tooltip = "Fake GI effect will fade out at this distance. \n\nThe default 1 should be fine for most games. \n\nNote: the large scale AO that is part of Fake GI is controlled by the AO max distance control.";
> = 1;

uniform float ao_radius < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 0.0; ui_max = 2; ui_step = 0.01;
	ui_tooltip = "Ambient Occlusion area size, as percent of screen. Bigger means larger areas of shade, but too big and you lose detail in the shade around small objects. Bigger can be slower too.";
	ui_label = "AO radius";
> = 1;


uniform float ao_shape_modifier < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 1; ui_max = 4000; ui_step = 1;
	ui_tooltip = "Ambient occlusion - weight against shading flat areas. Increase if you get deep shade in almost flat areas. Decrease if you get no-shade in concave areas areas that are shallow, but deep enough that they should be occluded.";
	ui_label = "AO shape modifier";
> = 1000;

uniform float ao_max_depth_diff < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 0; ui_max = 2; ui_step = 0.001;
	ui_tooltip = "Ambient occlusion biggest depth difference to allow, as percent of depth. Prevents nearby objects casting shade on distant objects. Decrease if you get dark halos around objects. Increase if holes that should be shaded are not.";
	ui_label = "AO max depth diff";
> = 0.5;

uniform float fxaa_bias < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 0; ui_max = 0.1; ui_step = 0.001;
	ui_tooltip = "Don't anti-alias edges with very small differences than this - this is to make sure subtle details can be sharpened and do not disappear. Decrease for smoother edges but at the cost of detail, increase to only sharpen high-contrast edges.";
	ui_label = "FXAA bias";
> = 0.020;


uniform float tone_map < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 1; ui_max = 9; ui_step = .1;
	ui_tooltip = "Note: this is ignored in HDR modes.\n\nIn the real world we can see a much wider range of brightness than a standard screen can produce. \n\nGames use tone mapping to reduce the dynamic range, especially in bright areas, to fit into display limits. \n\nTo calculate lighting effects like Fake GI accurately on SDR images, we want to undo tone mapping first, then reapply it afterwards. \n\nOptimal value depends on tone mapping method the game uses. You won't find that info published anywhere for most games. \n\nOur compensation is based on Reinhard tonemapping, but hopefully will be close enough if the game uses another curve like ACES. At 5 it's pretty close to ACES in bright areas but never steeper. \n\nApplies for Fake GI in SDR mode only.";
	ui_label = "Tone mapping compensation";
> = 3;

uniform float max_sharp_diff < __UNIFORM_SLIDER_FLOAT1
	ui_category = "Advanced Tuning and Configuration";
	ui_min = 0.05; ui_max = .25; ui_step = 0.01;
	ui_label = "Sharpen maximum change";
	ui_tooltip = "Maximum amount a pixel can be changed by the sharpen effect. Prevents oversharpening already sharp edges.";
> = 0.1;

uniform bool edge_detect_sharpen <
    ui_category = "Advanced Tuning and Configuration";
    ui_label = "Sharpen jagged edges less";
    ui_tooltip = "If enabled, the sharpen effect is reduced on jagged edges. It uses Fast FXAA's edge detection. \n\nIf this is disabled the image will be a bit sharper and, if Fast FXAA is also disabled, faster too. However, without this option sharpening can partially reintroduce jaggies that had been smoothed by Fast FXAA or the game's own anti-aliasing.";
    ui_type = "radio";
> = true;

uniform bool big_sharpen <
    ui_category = "Advanced Tuning and Configuration";
    ui_label = "Bigger sharpen & DOF";
    ui_tooltip = "Uses a bigger area, making both effects bigger. Affects FXAA too. \n\nThis is useful for high resolutions, with older games with low resolution textures, or viewing far from the screen. However, very fine details will be less accurate. \n\nIt increases overall sharpness too. Tip: use about half sharpen strength to get similar overall sharpness but with the bigger area.";
    ui_type = "radio";
> = false;

uniform bool abtest <
    ui_category = "Advanced Tuning and Configuration";
    ui_label = "A/B test";
    ui_tooltip = "Ignore this. Used by developer when testing and comparing algorithm changes.";
    ui_type = "radio";
> = false;

//////////////////////////////////////////////////////////////////////

// Tone map compensation to make top end closer to linear.
float3 undoTonemap(float3 c) {
	if(GLAMAYRE_COLOR_SPACE < 2)
	{
		c=saturate(c);
		c = c/(1.0-(1.0-rcp(tone_map))*c);
	}

	return c;
}

float3 reapplyTonemap(float3 c) {

	if(GLAMAYRE_COLOR_SPACE < 2)
	{
		c = c/((1-rcp(tone_map))*c+1.0);
	}

	return c;
}

///////////////////////////////////////////////////////////////
// Color space conversions
//////////////////////////////////////////////////////////////

float3 sRGBtoLinearAccurate(float3 r) {
	return (r<=.04045) ? (r/12.92) : pow(abs(r+.055)/1.055, 2.4);
}

float3 sRGBtoLinearFastApproximation(float3 r) {
	// pow is slow, use square (gamma 2.0)
	return max(r/12.92, r*r);
}

float3 sRGBtoLinear(float3 r) {
	if(fast_color_space_conversion==1) r = sRGBtoLinearFastApproximation(r);
	else if(fast_color_space_conversion==0) r = sRGBtoLinearAccurate(r);
	return r;
}

float3 linearToSRGBAccurate(float3 r) {
	return (r<=.0031308) ? (r*12.92) : (1.055*pow(abs(r), 1.0/2.4) - .055);
}

float3 linearToSRGBFastApproximation(float3 r) {
	// pow is slow, use square (gamma 2.0)
	return min(r*12.92, sqrt(r));
}


float3 linearToSRGB(float3 r) {
	if(fast_color_space_conversion==1) r = linearToSRGBFastApproximation(r);
	else if(fast_color_space_conversion==0) r = linearToSRGBAccurate(r);
	// if fast_color_space_conversion==2 then do nothing - we've already done it
	return r;
}


float3 PQtoLinearAccurate(float3 r) {
		// HDR10 we need to convert between PQ and linear. https://en.wikipedia.org/wiki/Perceptual_quantizer
		const float m1 = 1305.0/8192.0;
		const float m2 = 2523.0/32.0;
		const float c1 = 107.0/128.0;
		const float c2 = 2413.0/128.0;
		const float c3 = 2392.0/128.0;
		// Unnecessary max commands are to prevent compiler warnings, which might scare users.
		float3 powr = pow(max(r,0),1.0/m2);
		r = pow(max( max(powr-c1, 0) / ( c2 - c3*powr ), 0) , 1.0/m1);

		return r * 10000.0/HDR_WHITELEVEL;	// PQ output is 0-10,000 nits, but we want to rescale so whites at HDR_WHITELEVEL nits are mapped to 1 to match sRGB and scRGB range.
}

float3 PQtoLinearFastApproximation(float3 r) {
		// Approx PQ. pow is slow, Use square near zero, then x^4 for mid, x^8 for high.
		// I invented this - constants chosen by eye by comparing graphs of the curves. might be possible to optimize further to minimize % error.
		float3 square = r*r;
		float3 quad = square*square;
		float3 oct = quad*quad;
		r= max(max(square/340.0, quad/6.0), oct);

		return r * 10000.0/HDR_WHITELEVEL;	// PQ output is 0-10,000 nits, but we want to rescale so whites at HDR_WHITELEVEL nits are mapped to 1 to match sRGB and scRGB range.
}

float3 PQtoLinear(float3 r) {
	if(fast_color_space_conversion) r = PQtoLinearFastApproximation(r);
	else r = PQtoLinearAccurate(r);
	return r;
}

float3 linearToPQAccurate(float3 r) {
		// HDR10 we need to convert between PQ and linear. https://en.wikipedia.org/wiki/Perceptual_quantizer
		const float m1 = 1305.0/8192.0;
		const float m2 = 2523.0/32.0;
		const float c1 = 107.0/128.0;
		const float c2 = 2413.0/128.0;
		const float c3 = 2392.0/128.0;

		// PQ output is 0-10,000 nits, but we scaled that down to match sRGB and scRGB brightness range.
		r = r*(HDR_WHITELEVEL/10000.0);

		// Unnecessary max commands are to prevent compiler warnings, which might scare users.
		float3 powr = pow(max(r,0),m1);
		r = pow(max( ( c1 + c2*powr ) / ( 1 + c3*powr ), 0 ), m2);
		return r;
}

float3 linearToPQFastApproximation(float3 r) {
		// Approx PQ. pow is slow, sqrt faster, Use square near zero, then x^4 for mid, x^8 for high.
		// I invented this - constants chosen by eye by comparing graphs of the curves. might be possible to optimize further to minimize % error.

		// PQ output is 0-10,000 nits, but we scaled that down to match sRGB and scRGB brightness range.
		r = r*(HDR_WHITELEVEL/10000.0);

		float3 squareroot = sqrt(r);
		float3 quadroot = sqrt(squareroot);
		float3 octroot = sqrt(quadroot);
		r = min(octroot, min(sqrt(sqrt(6.0))*quadroot, sqrt(340.0)*squareroot ) );
		return r;
}

float3 linearToPQ(float3 r) {
	if(fast_color_space_conversion) r = linearToPQFastApproximation(r);
	else r = linearToPQAccurate(r);
	return r;
}

// Hybrid Log Gamma. From "ITU REC BT.2100".
// Untested: I think it's just used for video - I don't think any games use it?
// Simplified - assuming 1000 nit peak display luminance and no black level lift.
float3 linearToHLG(float3 r) {
	r = r*HDR_WHITELEVEL/1000;
	float a = 0.17883277;
	float b = 0.28466892; // 1-4a
	float c = 0.55991073; // .5-a*ln(4a)
	float3 s=sqrt(3*r);
	return (s<.5) ? s : ( log(12*r - b)*a+c);
}

float3 HLGtoLinear(float3 r) {
	float a = 0.17883277;
	float b = 0.28466892; // 1-4a
	float c = 0.55991073; // .5-a*ln(4a)
	r = (r<.5) ? r*r/3.0 : ( ( exp( (r - c)/a) + b) /12.0);
	return r * 1000/HDR_WHITELEVEL;

}

// Color space conversion.
float3 toLinearColorspace(float3 r) {
	if(GLAMAYRE_COLOR_SPACE == 2) r = r*(80.0/HDR_WHITELEVEL);
	else if(GLAMAYRE_COLOR_SPACE == 3) r = PQtoLinear(r);
	else if(GLAMAYRE_COLOR_SPACE == 4) r = HLGtoLinear(r);
	else r= sRGBtoLinear(r);
	// Bug: HLG not implemented... but I think it's just a video standard - I don't think any games use it?
	return r;
}

float3 toOutputColorspace(float3 r) {
	if(GLAMAYRE_COLOR_SPACE == 2) r=r*(HDR_WHITELEVEL/80.0); // scRGB is already linear
	else if(GLAMAYRE_COLOR_SPACE == 3) r = linearToPQ(r);
	else if(GLAMAYRE_COLOR_SPACE == 4) r = linearToHLG(r);
	else r= linearToSRGB(r);

	return r;
}

float getMaxColour()
{
	float m = 1;
	if(GLAMAYRE_COLOR_SPACE>=2) m = 10000.0/HDR_WHITELEVEL;
	if(GLAMAYRE_COLOR_SPACE==4) m = 1000.0/HDR_WHITELEVEL;
	return m;
}

///////////////////////////////////////////////////////////////
// END OF Color space conversions.
///////////////////////////////////////////////////////////////


sampler2D samplerColor
{
	// The texture to be used for sampling.
	Texture = ReShade::BackBufferTex;
#if BUFFER_COLOR_BIT_DEPTH > 8 || BUFFER_COLOR_SPACE > 1
	SRGBTexture = false;
#else
	SRGBTexture = true;
#endif
};


float4 getBackBufferLinear(float2 texcoord) {

	float4 c = tex2D( samplerColor, texcoord);
	c.rgb = toLinearColorspace(c.rgb);
	return c;
}

sampler2D samplerDepth
{
	// The texture to be used for sampling.
	Texture = ReShade::DepthBufferTex;

	// The method used for resolving texture coordinates which are out of bounds.
	// Available values: CLAMP, MIRROR, WRAP or REPEAT, BORDER.
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;

	// The magnification, minification and mipmap filtering types.
	// Available values: POINT, LINEAR.
	MagFilter = POINT;
	MinFilter = POINT;
	MipFilter = POINT;
};


// This is copy of reshade's getLinearizedDepth but using POINT sampling (LINEAR interpolation can cause artifacts - thin ghost of edge one radius away).
float pointDepth(float2 texcoord)
{
#if RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN
		texcoord.y = 1.0 - texcoord.y;
#endif
		texcoord.x /= RESHADE_DEPTH_INPUT_X_SCALE;
		texcoord.y /= RESHADE_DEPTH_INPUT_Y_SCALE;
#if RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET
		texcoord.x -= RESHADE_DEPTH_INPUT_X_PIXEL_OFFSET * BUFFER_RCP_WIDTH;
#else // Do not check RESHADE_DEPTH_INPUT_X_OFFSET, since it may be a decimal number, which the pre-processor cannot handle.
		texcoord.x -= RESHADE_DEPTH_INPUT_X_OFFSET / 2.000000001;
#endif
#if RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET
		texcoord.y += RESHADE_DEPTH_INPUT_Y_PIXEL_OFFSET * BUFFER_RCP_HEIGHT;
#else
		texcoord.y += RESHADE_DEPTH_INPUT_Y_OFFSET / 2.000000001;
#endif
		float depth = (float)tex2D(samplerDepth, texcoord);
		return depth;
}

float4 fixDepth4(float4 depth) {
		depth *= RESHADE_DEPTH_MULTIPLIER;

#if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
		const float C = 0.01;
		depth = (exp(depth * log(C + 1.0)) - 1.0) / C;
#endif
#if RESHADE_DEPTH_INPUT_IS_REVERSED
		depth = 1 - depth;
#endif
		const float N = 1.0;
		depth /= RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - depth * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - N);

		return depth;
}


float3 fixDepth3(float3 depth) {
		depth *= RESHADE_DEPTH_MULTIPLIER;

#if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
		const float C = 0.01;
		depth = (exp(depth * log(C + 1.0)) - 1.0) / C;
#endif
#if RESHADE_DEPTH_INPUT_IS_REVERSED
		depth = 1 - depth;
#endif
		const float N = 1.0;
		depth /= RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - depth * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - N);

		return depth;
}


static const uint FAKE_GI_WIDTH=192;
static const uint FAKE_GI_HEIGHT=108;

texture GITexture {
    Width = FAKE_GI_WIDTH*2;
    Height = FAKE_GI_HEIGHT*2 ;
    Format = RGBA16F;
	MipLevels=4;
};

sampler GITextureSampler {
    Texture = GITexture;
	AddressU = BORDER;
	AddressV = BORDER;
	AddressW = BORDER;
};


// The blur for Fake GI used to be based on "FGFX::FCSB[16X] - Fast Cascaded Separable Blur" by Alex Tuderan, but I have since replaced the code with my own blur algorithm, which can do a big blur in fewer passes.
// Still, credit to Alex for ideas - if you're interested in his blur algorithm see: https://github.com/AlexTuduran/FGFX/blob/main/Shaders/FGFXFastCascadedSeparableBlur16X.fx

texture HBlurTex {
    Width = FAKE_GI_WIDTH ;
    Height = FAKE_GI_HEIGHT ;
    Format = RGBA16F;
};

texture VBlurTex {
    Width = FAKE_GI_WIDTH ;
    Height = FAKE_GI_HEIGHT ;
    Format = RGBA16F;
};

sampler HBlurSampler {
    Texture = HBlurTex;
};

sampler VBlurSampler {
    Texture = VBlurTex;
};


float4 startGI_PS(float4 vpos : SV_Position, float2 texcoord : TexCoord) : COLOR
{
	float4 c=.5;

	c.rgb = getBackBufferLinear(texcoord).rgb;

	if( GLAMAYRE_COLOR_SPACE == 2 ) {
		// This fixes overly saturated colors in F1 2021 - I believe in linear color some lights are just really bright relative to everything and have too big an effect.
		// This is a reinhard tonemapper limiting brightness to 20.
		c=c/(1+0.05*c);
	}

	c.rgb=undoTonemap(c.rgb);

	// If sky detect is on... we don't want to make tops of buildings blue (or red in sunset) - make sky grayscale.
	if(gi_use_depth) {
		float depth = ReShade::GetLinearizedDepth(texcoord);
		c.rgb = lerp(c.rgb, length(c.rgb)*rsqrt(2), depth*depth);
		c.w=depth;
	}
	return c;
}


float4 bigBlur(sampler s, in float4 pos, in float2 texcoord, in float4 steps  ) {

	float2 pixelsize = 1/float2(FAKE_GI_WIDTH,FAKE_GI_HEIGHT);
	float4 c1 = tex2D(s, texcoord - pixelsize*steps.xy);
	float4 c2 = tex2D(s, texcoord - pixelsize*steps.zw);
	float4 c3 = tex2D(s, texcoord + pixelsize*steps.zw);
	float4 c4 = tex2D(s, texcoord + pixelsize*steps.xy);


	if(c1.w==0) c1.w = c3.w;
	if(c2.w==0) c2.w = c3.w;
	if(c3.w==0) c3.w = c2.w;
	if(c4.w==0) c4.w = c2.w;


	float4 c =.25*(c1+c2+c3+c4);

	if(gi_use_depth) {
		c1=lerp(c1, c, clamp(abs(5*( c1.w/min(c2.w,.5*(c2.w+c3.w)) -1 ) ), 0,1));
		c4=lerp(c4, c, clamp(abs(5*( c4.w/min(c3.w,.5*(c2.w+c3.w)) -1 ) ), 0,1));
		c2=lerp(c2, c, clamp(abs(3*(c2.w/c.w-1) ), 0,1));
		c3=lerp(c3, c, clamp(abs(3*(c3.w/c.w-1) ), 0,1));

		c = .25*(c1+c2+c3+c4);
	}


	return c;
}


float4 bigBlur1_PS(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD) : COLOR
{
	float4 result = bigBlur(GITextureSampler, pos, texcoord, float4(10.5,1.5,3.5,0.5) );

	return result;
}

float4 bigBlur2_PS(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD) : COLOR
{
	float4 result = bigBlur(HBlurSampler, pos, texcoord, float4(-1.5,10.5, -0.5,3.5) );

	return result;
}

float4 bigBlur3_PS(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD) : COLOR
{
	float4 result = bigBlur(VBlurSampler, pos, texcoord, float4(7.5,7.5,2.5,2.5) );
	return result;
}

float4 bigBlur4_PS(in float4 pos : SV_Position, in float2 texcoord : TEXCOORD) : COLOR
{
	float4 result = bigBlur(HBlurSampler, pos, texcoord, float4(-7.5,7.5,-2.5,2.5) );
	return result;
}


// This macro allows us to use a float4x4 like an array of up to 16 floats. Saves registers and enables some efficiencies compared to array of floats.
#define AO_MATRIX(a) (ao_point[(a)/4][(a)%4])

float3 Glamarye_Fast_Effects_PS(float4 vpos , float2 texcoord : TexCoord, bool gi_path)
{
	// center (original pixel)
	float3 c = getBackBufferLinear(texcoord).rgb;

	// center pixel depth
	float depth=0 ;

	if( (!gi_dof_safe_mode && (ao_enabled || gi_use_depth )) || dof_enabled || debug_mode || depth_detect || sky_detect) {
		// We don't use our special sampler here...
		depth = ReShade::GetLinearizedDepth(texcoord);
	}

	// multiplier to convert rgb to perceived brightness
	static const float3 luma = float3(0.2126, 0.7152, 0.0722);


  // skip all processing if in menu or video
  if(!(depth_detect && depth==0) && !(sky_detect && depth == 1) ) {

	float ratio=0;

	float3 smoothed=c;
	float3 sharp_diff = 0;
	if(fxaa_enabled || sharp_enabled || dof_enabled) {

		// Average of the four nearest pixels to each diagonal.
		float offset = big_sharpen ? 1.4 : .5;
		float3 ne = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*float2(offset,offset)).rgb;
		float3 sw = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*float2(-offset,-offset)).rgb;
		float3 se = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*float2(offset,-offset)).rgb;
		float3 nw = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*float2(-offset,offset)).rgb;

		// Average of surrounding pixels, both smoothing edges (FXAA).
		smoothed = (ne+nw)+(se+sw);
		if(big_sharpen) smoothed = clamp( (smoothed+c)/5, c/2.0, c*2.0);
		else smoothed = clamp( (smoothed-c)/3, c/2.0, c*2.0);
		smoothed = min(smoothed,getMaxColour());

		// Do we have horizontal or vertical line?
		float dy = dot(luma,abs((ne+nw)-(se+sw)));
		float dx = dot(luma,abs((ne+se)-(nw+sw)));
		bool horiz =  dy > dx;

		// We will proceed as if line is east to west. If it's north to south then rotate everything by 90 degrees.
		// First we get and approximation of the line of 3 pixels above and below c.
		float3 n2=horiz ? ne+nw : ne+se;
		float3 s2=horiz ? se+sw : nw+sw;
		if(big_sharpen) {
			n2*=.5;
			s2*=.5;
		}
		else
		{
			n2-=c;
			s2-=c;
		}

		// Calculate FXAA before sharpening.
		if(fxaa_enabled || (sharp_enabled && edge_detect_sharpen) ) {
			// Get two more pixels further away on the possible line.
			const float dist = 3.5;
			float2 wwpos = horiz ? float2(-dist, 0) : float2(0, +dist) ;
			float2 eepos = horiz ? float2(+dist, 0) : float2(0, -dist) ;

			float3 ww = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*wwpos).rgb;
			float3 ee = getBackBufferLinear( texcoord + BUFFER_PIXEL_SIZE*eepos).rgb;

			// We are looking for a step ███▄▄▄▄▄___ which should be smoothed to look like a slope.
			// We have a diamond of 4 values. We look for the strength of each diagonal. If one is significantly bigger than the other we have a step!
			//       n2
			// ww          ee
			//       s2

			float3 d1 = abs((ww-n2)-(ee-s2));
			float3 d2 = abs((ee-n2)-(ww-s2));


			// We compare the biggest diff to the total. The bigger the difference the stronger the step shape.
			// Add small constants to avoid blurring where not needed and to avoid divide by zero.

			float3 total_diff = (d1+d2) + .00004;
			float3 max_diff = max(d1,d2) + .00001 - fxaa_bias*sqrt(smoothed);

			// score between 0 and 1
			float score = dot(luma,(max_diff/total_diff)) ;

			// ratio of sharp to smoothed
			// If score > 0.5 then smooth. Anything less goes to zero.
			ratio = max( 2*score-1, 0);
		}

		if(sharp_enabled && sharp_strength) {
			// sharpen...
			// This is sharp gives slightly more natural looking shapes - the min+max trick effectively means the final output is weighted a little towards the median of the 4 surrounding values.
			sharp_diff = 2*c+(ne+nw+se+sw) - 3*(max(max(ne,nw),max(se,sw)) + min(min(ne,nw),min(se,sw)));

			// Sharpen by luma (brightness) to avoid oversaturated colors at edges.
			sharp_diff = dot(luma,sharp_diff);

			// simple sharp
			// sharp_diff = 2*c-.5*(ne+nw+se+sw);

			// avoid sharpennng so far the value doesn't go too dark or above 1
			float3 max_sharp=min(smoothed,.5*c);

			// limit sharpness near maximum color value.
			max_sharp = min(max_sharp,getMaxColour()-max(smoothed,c));

			// finally limit total sharpness to max_sharp_diff - this helps prevent oversharpening in mid-range
			// Minimum 0.00001 prevents artifacts when value is 0 or less (it can be less with HDR color).
			max_sharp = clamp(max_sharp, 0.00001, max_sharp_diff );

			// This is a bit like reinhard tonemapping applied to sharpness - smoother than clamping. steepness of curve chosen via our sharp_strength.
			sharp_diff = sharp_diff / ( rcp(sharp_strength) +abs(sharp_diff)/(max_sharp));

			// reduce sharpening if we have detected an edge
			if(edge_detect_sharpen) sharp_diff *= (1-ratio);
		}

		// Now apply FXAA after calculating but before applying sharpening.
		if(fxaa_enabled) c = lerp(c, smoothed, ratio);

		// apply sharpen
		c+=sharp_diff;

		// Now apply DOF blur, based on depth. Limit the change % to minimize artifacts on near/far edges.
		if(dof_enabled) {
			c=lerp(c, clamp(smoothed,c*.5,c*2), dof_strength*depth);
			sharp_diff *= dof_strength*depth;
		}
	}

	float ao = 0;

	const float shape = ao_shape_modifier*1.1920928955078125e-07F;

	// If bounce lighting isn't enabled we actually pretend it is using c*smoothed to get better color in bright areas (otherwise shade can be too deep or too gray).
	float3 bounce=0;

	float smoke_fix;

	if(gi_path || ao_enabled) {
		// Prevent AO affecting areas that are white - saturated light areas. These are probably clouds or explosions and shouldn't be shaded.
	    smoke_fix=max(0,(1-reduce_ao_in_light_areas*length(min(c,smoothed))));

		// Tone map fix helps improve colors in brighter areas.
		c=undoTonemap(c);
	}

	float4 gi=0;
	float4 bounce_area = 0;
	if(gi_path) {

		bounce_area = tex2Dlod(GITextureSampler, float4(texcoord.x,texcoord.y, 0, 2.5));

		float2 gi_adjust_vector=0;

		if(gi_use_depth) {
			if(gi_dof_safe_mode) {
				depth = tex2Dlod(GITextureSampler, float4(texcoord.x,texcoord.y, 0, 1.5)).w;
			} else  {
				// We want to sample GI color a little bit in the direction of the normal.
				float4 local_slope = float4(ddx(depth), ddy(depth), 0.1*BUFFER_PIXEL_SIZE);

				gi_adjust_vector = normalize(local_slope).xy*gi_shape;
			}
			// local area enhanced AO
			float abs_diff = abs(depth-bounce_area.w);
			if( abs_diff>shape*2) ao += gi_local_ao_strength*.1*sign(depth-bounce_area.w);
			if(gi_dof_safe_mode) depth=bounce_area.w;
		}
		gi = tex2D(VBlurSampler, texcoord+gi_adjust_vector);

		if(gi_use_depth) { // Calculate local bounce.
			// Area brightness.
			// Why not use dot(luma,gi.rgb) to get luminance? I tried and min+max works better.
			float gi_bright = max(gi.r,max(gi.g,gi.b)) + min(gi.r,min(gi.g,gi.b));

			// Estimate amount of white light hitting area.
			float light = gi_bright+.005;

			// Estimate base unlit color of c.
			float3 unlit_c2 = c/light;

			// We take our bounce light and multiply it by base unlit color of c to get amount reflected from c.
			bounce=lerp(bounce, unlit_c2*max(0,2*bounce_area.rgb-c), bounce_multiplier);
		}

		float contrast = dot(luma,max(0,c-sharp_diff)/max(bounce_area.rgb+gi.rgb,0.00001));
		contrast = (contrast)/(1+contrast)+.66666666667;


		contrast = lerp(1, contrast, gi_contrast);

		// Fake Global Illumination - even without depth it works better than you might expect!
		// Estimate ambient light hitting pixel as blend between local and area brightness.


		float3 avg_light = length((2*gi_strength)*c+gi.rgb)/(1+2*gi_strength);

		float3 ambient =  min(avg_light, lerp(1, 1+length(gi.rgb/(c+gi.rgb)),gi_saturation*gi_strength)*gi.rgb );

		float3 gi_bounce = (1+.5*gi_saturation*gi_strength)*c*gi.rgb/ambient;

		// This adjustment is to avoid nearby objects casting color onto ones much further away.
		float gi_ratio = min(1, (gi.w+0.00001)/(depth+0.00001));

		// This adjustment is to fade out as we reach the sky.
		if(gi_use_depth || sky_detect) gi_ratio *= max(0, 1-depth*depth*depth*rcp(gi_max_distance*gi_max_distance*gi_max_distance));

		c = lerp(c, gi_bounce , .4*gi_ratio);
		c = c*contrast;
 	}


	// Fast screen-space ambient occlusion. It does a good job of shading concave corners facing the camera, even with few samples.
	// Depth check is to minimize performance impact areas beyond our max distance, or on games that don't give us depth, if AO left on by mistake.
	if( ao_enabled && !gi_dof_safe_mode && depth>0 && depth<ao_fog_fix ) {

		// Checkerboard pattern of 1s and 0s ▀▄▀▄▀▄. Single layer of dither works nicely to allow us to use 2 radii without doubling the samples per pixel. More complex dither patterns are noticeable and annoying.
		uint square =  (uint(vpos.x+vpos.y)) % 2;
		uint circle=0;
		if(ao_big_dither) {
			circle = (uint(vpos.y/2))%2;
		}

		uint points = clamp(FAST_AO_POINTS,2, 16);

		float2 ao_lengths[2];

		ao_lengths[0] = float2(.01,.004);
		if(!ao_big_dither) ao_lengths[0].x = (min(.002*points,.01));
		ao_lengths[1] = float2(.0055,.0085);


		// Distance of points is either ao_radius or ao_radius*.4 (distance depending on position in checkerboard).
		// Also, note, for points < 5 we reduce larger radius a bit - with few points we need more precision near center.
		float ao_choice = (square ? ao_lengths[circle].x : ao_lengths[circle].y );
		float the_vector_len= ao_radius * (1-depth*.8) * ao_choice;

		uint i; // loop counter

		// Get circle of depth samples.
		float2 the_vector;

		// This is the angle between the same point on adjacent pixels, or half the angle between adjacently points on this pixel.
		const float angle = radians(180)/points;


		// This seems weird, but it improves performance more than reducing points by 1! Negligible impact on image (unless you set a very small radius).
		// Reason: GPUs process pixels in groups of 4. By making each group share a center we make some of depth samples the same between opposites. By reading fewer distinct points overall we improve cache performance.
		texcoord = (floor((vpos.xy)/2)*2+0.5)*BUFFER_PIXEL_SIZE;


#if FAST_AO_POINTS == 6
		float2x3 ao_point ;
		ao_point[0]=0;
		ao_point[1]=0;

		[unroll]
		for(i = 0; i< 2; i++) {
			// Distance of points is either ao_radius or ao_radius*.4 (distance depending on position in checkerboard).
			// We want (i*2+square)*angle, but this is a trick to help the optimizer generate constants instead of trig functions.
			// Also, note, for points < 5 we reduce larger radius a bit - with few points we need more precision near center.

			float2 outer_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2+.5)*angle), cos((i*2+.5)*angle) );
			float2 inner_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2-.5)*angle), cos((i*2-.5)*angle) );

			the_vector = the_vector_len * (!square ? inner_circle : outer_circle);

			// Get the depth at each point - must use POINT sampling, not LINEAR to avoid ghosting artifacts near object edges.
			ao_point[i][0] = pointDepth( texcoord+the_vector);
		}

		[unroll]
		for(i = 2; i< 4; i++) {
			// Distance of points is either ao_radius or ao_radius*.4 (distance depending on position in checkerboard).
			// We want (i*2+square)*angle, but this is a trick to help the optimizer generate constants instead of trig functions.
			// Also, note, for points < 5 we reduce larger radius a bit - with few points we need more precision near center.

			float2 outer_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2+.5)*angle), cos((i*2+.5)*angle) );
			float2 inner_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2-.5)*angle), cos((i*2-.5)*angle) );

			the_vector = the_vector_len * (!square ? inner_circle : outer_circle);

			// Get the depth at each point - must use POINT sampling, not LINEAR to avoid ghosting artifacts near object edges.
			ao_point[i-2][1] = pointDepth( texcoord+the_vector);
		}

		[unroll]
		for(i = 4; i< 6; i++) {
			// Distance of points is either ao_radius or ao_radius*.4 (distance depending on position in checkerboard).
			// We want (i*2+square)*angle, but this is a trick to help the optimizer generate constants instead of trig functions.
			// Also, note, for points < 5 we reduce larger radius a bit - with few points we need more precision near center.

			float2 outer_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2+.5)*angle), cos((i*2+.5)*angle) );
			float2 inner_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2-.5)*angle), cos((i*2-.5)*angle) );

			the_vector = the_vector_len * (!square ? inner_circle : outer_circle);

			// Get the depth at each point - must use POINT sampling, not LINEAR to avoid ghosting artifacts near object edges.
			ao_point[i-4][2] = pointDepth( texcoord+the_vector);
		}


		float max_depth = depth+0.01*ao_max_depth_diff;
		float min_depth_sq = sqrt(depth)-0.01*ao_max_depth_diff;
		min_depth_sq *=  min_depth_sq;

		float2x3 adj_point;
		adj_point[0]=0;
		adj_point[1]=0;

		[unroll]
		for(i = 0 ; i<2; i++) {
			ao_point[i] = fixDepth3(ao_point[i]);
			ao_point[i] = (ao_point[i] < min_depth_sq) ? -depth : min(ao_point[i], max_depth);
		}

		float2x3 opposite;

		opposite[0] = ao_point[1].yzx;
		opposite[1] = ao_point[0].zxy;

		[unroll]
		for(i = 0 ; i<2; i++) {
			ao_point[i] = (ao_point[i] >= 0) ? ao_point[i] : depth*2-abs(opposite[i]);
		}

		adj_point[0] = ao_point[1];
		adj_point[1] = ao_point[0].yzx;

		// Now estimate the local variation - sum of differences between adjacent points.

		// This uses fewer instruction but causes a compiler warning. I'm going with the clearer loop below.
		// float variance = dot(mul((ao_point[i]-adj_point[i])*(ao_point[i]-adj_point[i]),float4(1,1,1,1)),float4(1,1,1,1)/(2*points));

		float3 variance = 0;

		for(i = 0 ; i<2; i++) {
			variance += (ao_point[i]-adj_point[i])*(ao_point[i]-adj_point[i]);
		}

		variance = sqrt(dot(variance, float3(1,1,1)/(2*points)));

		// Minimum difference in depth - this is to prevent shading areas that are only slightly concave.
		variance += shape;

		float3 ao3=0;

		[unroll]
		for(i = 0 ; i<2; i++) {

			float3 near=min(ao_point[i],adj_point[i]);
			float3 far=max(ao_point[i],adj_point[i]);

			// This is the magic that makes shaded areas smoothed instead of band of equal shade. If both points are in front, but one is only slightly in front (relative to variance) then.
			near -= variance;
			far  += variance;

			// Linear interpolation.
			float3 crossing = (depth-near)/(far-near);

			// If depth is between near and far, crossing is between 0 and 1. If not, clamp it. Then adjust it to be between -1 and +1.
			crossing = 2*clamp(crossing,0,1)-1;

			ao3 += crossing;
		}

		// Because of our checkerboard pattern it can be too dark in the inner_circle and create a noticeable step. This softens the inner circle (which will be darker anyway because outer_circle is probably dark too).
		// if(!square) ao3 *=(2.0/3.0);
		ao3 *= (50*abs(ao_choice)+.5);

		ao += dot(ao3, float3(1,1,1)/points);

#else
		float4x4 ao_point ;
		ao_point[0]=0;
		ao_point[1]=0;
		ao_point[2]=0;
		ao_point[3]=0;

		[unroll]
		for(i = 0; i< points; i++) {
			// We want (i*2+square)*angle, but this is a trick to help the optimizer generate constants instead of trig functions.

			float2 outer_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2+.5)*angle), cos((i*2+.5)*angle) );
			float2 inner_circle = 1/normalize(BUFFER_SCREEN_SIZE)*float2( sin((i*2-.5)*angle), cos((i*2-.5)*angle) );

			the_vector = the_vector_len * (square ? inner_circle : outer_circle);


			// Get the depth at each point - must use POINT sampling, not LINEAR to avoid ghosting artifacts near object edges.
			AO_MATRIX(i) = pointDepth( texcoord+the_vector);
		}



		float max_depth = depth+0.01*ao_max_depth_diff;
		float min_depth_sq = sqrt(depth)-0.01*ao_max_depth_diff;
		min_depth_sq *=  min_depth_sq;

		float4x4 adj_point;
		adj_point[0]=0;
		adj_point[1]=0;
		adj_point[2]=0;
		adj_point[3]=0;

		[unroll]
		for(i = 0 ; i<(points+3)/4; i++) {
			ao_point[i] = fixDepth4(ao_point[i]);
			ao_point[i] = (ao_point[i] < min_depth_sq) ? -depth : min(ao_point[i], max_depth);
		}

		float4x4 opposite;
		if(FAST_AO_POINTS==8) {
			opposite[0] = ao_point[1];
			opposite[1] = ao_point[0];
		}
		else if(FAST_AO_POINTS==4) {
			opposite[0] = ao_point[0].barg;
		}
		else {
			[unroll]
			for(i = 0; i<points; i++) {
				// If AO_MATRIX(i) is much closer than depth then it's a different object and we don't let it cast shadow - instead predict value based on opposite point(s) (so they cancel out).
				opposite[i/4][i%4] = AO_MATRIX((i+points/2)%points);
				if(points%2) opposite[i/4][i%4] = (opposite[i/4][i%4] + AO_MATRIX((1+i+points/2)%points) ) /2;
			}
		}
		[unroll]
		for(i = 0 ; i<(points+3)/4; i++) {
			ao_point[i] = (ao_point[i] >= 0) ? ao_point[i] : depth*2-abs(opposite[i]);
		}


		if(FAST_AO_POINTS==8) {
			adj_point[0].yzw = ao_point[0].xyz;
			adj_point[1].yzw = ao_point[1].xyz;
			adj_point[0].x = ao_point[1].w;
			adj_point[1].x = ao_point[0].w;
		}
		else if(FAST_AO_POINTS==4) {
			adj_point[0] = ao_point[0].wxyz;
		} else {
			adj_point[i-1]=ao_point[i-1];  // For not 4 nor 8 initialize to the same we don't mess up the variance.
			[unroll]
			for(i = 0; i<points; i++) {
				adj_point[i/4][i%4] = AO_MATRIX((i+1)%points);
			}
		}

		// Now estimate the local variation - sum of differences between adjacent points.

		// This uses fewer instruction but causes a compiler warning. I'm going with the clearer loop below.
		// float variance = dot(mul((ao_point[i]-adj_point[i])*(ao_point[i]-adj_point[i]),float4(1,1,1,1)),float4(1,1,1,1)/(2*points));

		float4 variance = 0;

		for(i = 0 ; i<(points+3)/4; i++) {
			variance += (ao_point[i]-adj_point[i])*(ao_point[i]-adj_point[i]);
		}

		variance = sqrt(dot(variance, float4(1,1,1,1)/(2*points)));

		// Minimum difference in depth - this is to prevent shading areas that are only slightly concave.
		variance += shape;

		float4 ao4=0;

		[unroll]
		for(i = 0 ; i<(points)/4; i++) {

			float4 near=min(ao_point[i],adj_point[i]);
			float4 far=max(ao_point[i],adj_point[i]);

			// This is the magic that makes shaded areas smoothed instead of band of equal shade. If both points are in front, but one is only slightly in front (relative to variance) then.
			near -= variance;
			far  += variance;

			// Linear interpolation.
			float4 crossing = (depth-near)/(far-near);

			// If depth is between near and far, crossing is between 0 and 1. If not, clamp it. Then adjust it to be between -1 and +1.
			crossing = 2*clamp(crossing,0,1)-1;

			ao4 += crossing;
		}
		if(points%4) {
			float4 near=min(ao_point[i],adj_point[i]);
			float4 far=max(ao_point[i],adj_point[i]);

			// This is the magic that makes shaded areas smoothed instead of band of equal shade. If both points are in front, but one is only slightly in front (relative to variance) then.
			near -= variance;
			far  += variance;

			// Linear interpolation.
			float4 crossing = (depth-near)/(far-near);

			// If depth is between near and far, crossing is between 0 and 1. If not, clamp it. Then adjust it to be between -1 and +1.
			crossing = 2*clamp(crossing,0,1)-1;

			if(points%4==3) crossing.w=0;
			else if(points%4==2) crossing.zw=0;
			else if(points%4==1) crossing.yzw=0;

			ao4 += crossing;
		}

		// Because of our checkerboard pattern it can be too dark in the inner_circle and create a noticeable step. This softens the inner circle (which will be darker anyway because outer_circle is probably dark too).
		// if(!square || points==2) ao4 *=(2.0/3.0);
		ao4 *= (50*abs(ao_choice)+.5);

		ao += dot(ao4, float4(1,1,1,1)/points);
#endif

	}



	// debug Show ambient occlusion mode
	if(debug_mode==2 ) c=undoTonemap(.33);

	// Weaken the AO effect if depth is a long way away. This is to avoid artifacts when there is fog/haze/darkness in the distance.
	float fog_fix_multiplier = clamp((1-depth/ao_fog_fix)*2,0,1 );

	if(gi_path && gi_use_depth && depth) {
			float depth_ratio = gi.w/depth;

			depth_ratio=clamp(depth_ratio,1-depth_ratio,1); // Reduce effect if ratio < .5 (i.e pixel is more than twice the area depth).

			c = lerp(c, c*depth_ratio, gi_ao_strength*fog_fix_multiplier*smoke_fix);
	}

	ao = ao*fog_fix_multiplier;

	// If ao is negative it's an exposed area to be brightened (or set to 0 if shine is off).
	if (ao<0) {
		ao*=ao_shine_strength*.5;
		ao*=smoke_fix;

		c=c*(1-ao);
	}
	else if(ao>0) {
		bounce = bounce*ao_strength*min(ao,.5);

		ao *= ao_strength*1.8; // multiply to compensate for the bounce value we're adding

		bounce = min(c*ao,bounce); // Make sure bounce doesn't make pixel brighter than original.

		ao*=smoke_fix;

		// Apply AO and clamp the pixel to avoid going completely black or white.
		c = clamp( c*(1-ao) + bounce,  0.25*c, c  );
	}


	if(gi_path) {


		// Show GI light.
		if(debug_mode==5) c=gi.rgb;

		// These were used in development are aren't really useful for users. KISS
		// if(debug_mode==6) c=bounce;
		// if(debug_mode==7) c=(bounce_area.rgb+gi.rgb)/2;
		// if(debug_mode==8) c= contrast*.2;
		// if(debug_mode==9) c=depth_ratio*.25;
		// if(debug_mode==10) c=gi.w;
	}

	if(gi_path || ao_enabled) c=reapplyTonemap(c);

	// Debug mode: make the fxaa edges highlighted in green.
	if(debug_mode==1)	c = lerp(c.ggg, float3(0,1,0), ratio*ratio);
	if(debug_mode==4)	c = lerp(depth, float3(0,1,0), ratio*ratio);

  }



  // Show depth buffer mode.
  if(debug_mode == 3) c = depth ;

  c.rgb = toOutputColorspace(c);

  return c;
}

// Vertex shader generating a triangle covering the entire screen.
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
	texcoord.x = (id == 2) ? 2.0 : 0.0;
	texcoord.y = (id == 1) ? 2.0 : 0.0;
	position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}



float3 Glamarye_Fast_Effects_all_PS(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
	return  Glamarye_Fast_Effects_PS(vpos,  texcoord, true);
}

float3 Glamarye_Fast_Effects_without_Fake_GI_PS(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
	return  Glamarye_Fast_Effects_PS(vpos,  texcoord, false);
}



technique Glamarye_Fast_Effects_with_Fake_GI <
	ui_tooltip = "Designed for speed, it combines multiple effects in one shader. Higher quality effects exist, but not this fast. \nThe aim is to look good enough without destroying your framerate. If you turn off your game's built-in post-processing options and use these instead you may even get a higher framerate!\n"
				 "\nBasic effects:\n"
				 "1. FXAA. Fixes jagged edges. \n"
				 "2. Intelligent Sharpening. \n"
				 "3. Ambient occlusion. Shades areas that receive less ambient light. It can optionally brighten exposed shapes too, making the image more vivid (AO shine setting).\n"
				 "4. Subtle Depth of Field. Softens distant objects.\n"
				 "5. Detect Menus and Videos. Disables effects when not in-game.\n"
				 "6. Detect Sky. Disable effects for background images behind the 3D world\n"
				 "\nFake Global Illumination effects:\n"
				 " (these attempts to look like fancy GI shaders but using very simple approximations. Not as realistic, but very fast.)\n"
				 "1. Indirect lighting. Pixels take color from the surrounding area (depth optional!)\n"
				 "2. Adaptive contrast enhancement. Enhances clarity.\n"
				 "3. Large scale ambient occlusion. Big area but very soft.\n"
				 "4. Local bounce light. Enhances ambient occlusion, adding color to it.\n";

	>
{
	pass makeGI
	{
		VertexShader = PostProcessVS;
		PixelShader = startGI_PS;
		RenderTarget = GITexture;
	}

	pass  {
        VertexShader = PostProcessVS;
        PixelShader  = bigBlur1_PS;
        RenderTarget = HBlurTex;
    }

    pass  {
        VertexShader = PostProcessVS;
        PixelShader  = bigBlur2_PS;
        RenderTarget = VBlurTex;
    }

	pass  {
        VertexShader = PostProcessVS;
        PixelShader  = bigBlur3_PS;
        RenderTarget = HBlurTex;
    }

    pass  {
        VertexShader = PostProcessVS;
        PixelShader  = bigBlur4_PS;
        RenderTarget = VBlurTex;
    }

	pass {
		VertexShader = PostProcessVS;
		PixelShader = Glamarye_Fast_Effects_all_PS;

		// SDR or HDR mode?
#if BUFFER_COLOR_BIT_DEPTH > 8 || BUFFER_COLOR_SPACE > 1
			SRGBWriteEnable = false;
#else
			SRGBWriteEnable = true;
#endif
	}


}

technique Glamarye_Fast_Effects_without_Fake_GI <
	ui_tooltip = "Designed for speed, it combines multiple effects in one shader. Higher quality effects exist, but not this fast. \nThe aim is to look good enough without destroying your framerate. If you turn off your game's built-in post-processing options and use these instead you may even get a higher framerate!\n"
				 "\nBasic effects:\n"
				 "1. FXAA. Fixes jagged edges. \n"
				 "2. Intelligent Sharpening. \n"
				 "3. Ambient Occlusion. Shades areas that receive less ambient light. It can optionally brighten exposed shapes too, making the image more vivid (AO shine setting).\n"
				 "4. Subtle Depth of Field. Softens distant objects.\n"
				 "5. Detect Menus and Videos. Disables effects when not in-game.\n"
				 "6. Detect Sky. Disable effects for background images behind the 3D world\n."
				 "This version does not include the Fake GI effects, therefore is faster than the full version.\n";
	>
{
	pass Glamayre
	{
		VertexShader = PostProcessVS;
		PixelShader = Glamarye_Fast_Effects_without_Fake_GI_PS;

		// SDR or HDR mode?
#if BUFFER_COLOR_BIT_DEPTH > 8 || BUFFER_COLOR_SPACE > 1
			SRGBWriteEnable = false;
#else
			SRGBWriteEnable = true;
#endif
	}

}




// END OF NAMESPACE
}
