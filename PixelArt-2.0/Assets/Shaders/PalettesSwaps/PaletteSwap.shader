Shader"PixelArt_2.0/PaletteSwap"
{
    Properties
    {
        _MainTex("Diffuse", 2D) = "white" {}
        // Single 1D RGB palette - width = palette size, height = 1
        _PaletteTex("Palette (RGB 1D)", 2D) = "white" {}
        _PaletteCount("Palette Count", Float) = 8
        _MaskTex("Mask", 2D) = "white" {}
        _NormalMap("Normal Map", 2D) = "bump" {}
        [MaterialToggle] _ZWrite("ZWrite", Float) = 0
        [MaterialToggle] _UseLab("UseLab", Float) = 1
        [MaterialToggle] _BeforeShading("SwapBeforeShading", Float) = 1

        // Legacy properties. They're here so that materials using this shader can gracefully fallback to the legacy sprite shader.
        [HideInInspector] _Color("Tint", Color) = (1,1,1,1)
        [HideInInspector] _RendererColor("RendererColor", Color) = (1,1,1,1)
        [HideInInspector] _AlphaTex("External Alpha", 2D) = "white" {}
        [HideInInspector] _EnableExternalAlpha("Enable External Alpha", Float) = 0
    }

    SubShader
    {
        Tags {"Queue" = "Transparent" "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" }

        Blend SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
        Cull Off
        ZWrite [_ZWrite]

        Pass
        {
            Tags { "LightMode" = "Universal2D" }

            HLSLPROGRAM
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/Core2D.hlsl"

            #pragma vertex CombinedShapeLightVertex
            #pragma fragment CombinedShapeLightFragment

            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/ShapeLightShared.hlsl"

            // GPU Instancing
            #pragma multi_compile_instancing
            #pragma multi_compile _ DEBUG_DISPLAY SKINNED_SPRITE

            struct Attributes
            {
                float3 positionOS   : POSITION;
                float4 color        : COLOR;
                float2 uv           : TEXCOORD0;
                UNITY_SKINNED_VERTEX_INPUTS
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4  positionCS  : SV_POSITION;
                half4   color       : COLOR;
                float2  uv          : TEXCOORD0;
                half2   lightingUV  : TEXCOORD1;
                #if defined(DEBUG_DISPLAY)
                float3  positionWS  : TEXCOORD2;
                #endif
                UNITY_VERTEX_OUTPUT_STEREO
            };

            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/LightingUtility.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/DebugMipmapStreamingMacros.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            UNITY_TEXTURE_STREAMING_DEBUG_VARS_FOR_TEX(_MainTex);

            TEXTURE2D(_PaletteTex);
            SAMPLER(sampler_PaletteTex);

            TEXTURE2D(_MaskTex);
            SAMPLER(sampler_MaskTex);

            // NOTE: Do not ifdef the properties here as SRP batcher can not handle different layouts.
            CBUFFER_START(UnityPerMaterial)
                half4 _Color;
                int _PaletteCount;
                bool  _UseLab;
                bool _BeforeShading;
            CBUFFER_END

            #if USE_SHAPE_LIGHT_TYPE_0
            SHAPE_LIGHT(0)
            #endif

            #if USE_SHAPE_LIGHT_TYPE_1
            SHAPE_LIGHT(1)
            #endif

            #if USE_SHAPE_LIGHT_TYPE_2
            SHAPE_LIGHT(2)
            #endif

            #if USE_SHAPE_LIGHT_TYPE_3
            SHAPE_LIGHT(3)
            #endif

            Varyings CombinedShapeLightVertex(Attributes v)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                UNITY_SKINNED_VERTEX_COMPUTE(v);

                SetUpSpriteInstanceProperties();
                v.positionOS = UnityFlipSprite(v.positionOS, unity_SpriteProps.xy);
                o.positionCS = TransformObjectToHClip(v.positionOS);
                #if defined(DEBUG_DISPLAY)
                o.positionWS = TransformObjectToWorld(v.positionOS);
                #endif
                o.uv = v.uv;
                o.lightingUV = half2(ComputeScreenPos(o.positionCS / o.positionCS.w).xy);

                o.color = v.color * _Color * unity_SpriteColor;
                return o;
            }

            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/CombinedShapeLightShared.hlsl"

            // -------- sRGB (linear) -> XYZ (D65) -> Lab helpers --------
            float3 LinearRGB_to_XYZ(float3 rgb)
            {
                const float3x3 M = float3x3(
                    0.4124564, 0.3575761, 0.1804375,
                    0.2126729, 0.7151522, 0.0721750,
                    0.0193339, 0.1191920, 0.9503041
                );
                return mul(M, rgb);
            }
            float f_xyz(float t)
            {
                const float eps = 216.0/24389.0; // (6/29)^3
                const float kap = 24389.0/27.0;
                return (t > eps) ? pow(t, 1.0/3.0) : ((kap*t + 16.0)/116.0);
            }
            float3 XYZ_to_Lab(float3 xyz)
            {
                const float3 w = float3(0.95047, 1.0, 1.08883); // D65 whites
                float3 r = float3(xyz.x/w.x, xyz.y/w.y, xyz.z/w.z);
                float fx = f_xyz(r.x), fy = f_xyz(r.y), fz = f_xyz(r.z);
                return float3(116.0*fy - 16.0, 500.0*(fx - fy), 200.0*(fy - fz));
            }
            float3 RGB_to_Lab(float3 rgbLinear)
            {
                if (!_UseLab)
                    return rgbLinear;

                return XYZ_to_Lab(LinearRGB_to_XYZ(rgbLinear));
            }

            // --- Lab helpers ---
            float Chroma(float3 lab) { return sqrt(lab.y*lab.y + lab.z*lab.z); }
            float HueAngle(float a, float b) { return atan2(b, a); } // radians

            // Wrap difference of angles to [-PI, PI]
            float DeltaHue(float h1, float h2)
            {
                float dh = h1 - h2;
                // wrap
                dh = (dh >  3.14159265) ? dh - 6.28318531 : dh;
                dh = (dh < -3.14159265) ? dh + 6.28318531 : dh;
                return dh;
            }

            float DeltaE94_2(float3 lab1, float3 lab2)
            {
                // Textiles weights (good for images). For “graphics” set kL=1, K1=0.045, K2=0.015
                const float kL = 2.0; // lightness param (textiles often 2.0)
                const float K1 = 0.048;
                const float K2 = 0.014;
                const float kC = 1.0, kH = 1.0;

                float dL = lab1.x - lab2.x;

                float C1 = Chroma(lab1), C2 = Chroma(lab2);
                float dC = C1 - C2;

                float h1 = HueAngle(lab1.y, lab1.z);
                float h2 = HueAngle(lab2.y, lab2.z);
                float dH = DeltaHue(h1, h2);
                // ΔH^2 = Δa^2 + Δb^2 − ΔC^2  (avoid precision issues)
                float da = lab1.y - lab2.y, db = lab1.z - lab2.z;
                float dH2 = da*da + db*db - dC*dC;

                float SL = (kL == 1.0) ? 1.0 : 1.0; // left for clarity; some forms vary with L*
                float SC = 1.0 + K1*C1;
                float SH = 1.0 + K2*C1;

                float vL = dL/(kL*SL);
                float vC = dC/(kC*SC);
                float vH2 = dH2/(kH*SH); // already squared

                return vL*vL + vC*vC + vH2;
            }

            float DeltaE_ChromaPriority_2(float3 lab1, float3 lab2)
            {
                float C1 = Chroma(lab1), C2 = Chroma(lab2);
                float dC = C1 - C2;
                float dL = lab1.x - lab2.x;
                float da = lab1.y - lab2.y, db = lab1.z - lab2.z;
                float dH2 = da*da + db*db - dC*dC;
                return dL*dL + 2.0*dC*dC + dH2; // chroma twice as important
            }

            // L1 / Manhattan in Lab
            float DeltaLab_L1(float3 lab1, float3 lab2)
            {
                float3 d = abs(lab1 - lab2);
                return d.x + d.y + d.z;
            }

            // Chebyshev / Max channel difference in Lab
            float DeltaLab_Chebyshev(float3 lab1, float3 lab2)
            {
                float3 d = abs(lab1 - lab2);
                return max(d.x, max(d.y, d.z));
            }

            // ΔE_76 in Lab (squared)
            float ColorDistance(float3 lab1, float3 lab2)
            {
                float3 d = lab1 - lab2;
                return dot(d,d);
            }

            half3 RemapColorPalette(half3 inRGB)
            {
                float3 lab = RGB_to_Lab((float3)inRGB);

                int count = (int) clamp(_PaletteCount, 1.0, 2048.0);
                float bestD = 1e30;
                float3 bestRGB = 0;

                [loop]
                for (int k = 0; k < count; ++k)
                {
                    float u = (k + 0.5) / count;
                    float3 pRGB = SAMPLE_TEXTURE2D_LOD(_PaletteTex, sampler_PaletteTex, float2(u, 0.5), 0).rgb; // assumed linear
                    float3 pLab = RGB_to_Lab(pRGB);
                    float d = ColorDistance(lab, pLab);
                    
                    if (d < bestD) 
                    {
                        bestD = d;
                        bestRGB = pRGB;
                    }
                }

                return bestRGB;
            }

            half4 CombinedShapeLightFragment(Varyings i) : SV_Target
            {
                half4 main = i.color * SAMPLE_TEXTURE2D_LOD(_MainTex, sampler_MainTex, i.uv, 0);
                const half4 mask = SAMPLE_TEXTURE2D(_MaskTex, sampler_MaskTex, i.uv);
                SurfaceData2D surfaceData;
                InputData2D inputData;

                if(_BeforeShading)
                {
                    main.rgb = RemapColorPalette(main.rgb);   
                }

                InitializeSurfaceData(main.rgb, main.a, mask, surfaceData);
                InitializeInputData(i.uv, i.lightingUV, inputData);

                SETUP_DEBUG_TEXTURE_DATA_2D_NO_TS(inputData, i.positionWS, i.positionCS, _MainTex);

                half4 colorOut = CombinedShapeLightShared(surfaceData, inputData); 

                if(!_BeforeShading)
                {
                    colorOut.rgb = RemapColorPalette(colorOut.rgb);   
                }

                return colorOut;
            }
            ENDHLSL
        }

        Pass
        {
            ZWrite Off

            Tags { "LightMode" = "NormalsRendering"}

            HLSLPROGRAM
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/Core2D.hlsl"

            #pragma vertex NormalsRenderingVertex
            #pragma fragment NormalsRenderingFragment

            // GPU Instancing
            #pragma multi_compile_instancing
            #pragma multi_compile _ SKINNED_SPRITE

            struct Attributes
            {
                float3 positionOS   : POSITION;
                float4 color        : COLOR;
                float2 uv           : TEXCOORD0;
                float4 tangent      : TANGENT;
                UNITY_SKINNED_VERTEX_INPUTS
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4  positionCS      : SV_POSITION;
                half4   color           : COLOR;
                float2  uv              : TEXCOORD0;
                half3   normalWS        : TEXCOORD1;
                half3   tangentWS       : TEXCOORD2;
                half3   bitangentWS     : TEXCOORD3;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            TEXTURE2D(_NormalMap);
            SAMPLER(sampler_NormalMap);

            // NOTE: Do not ifdef the properties here as SRP batcher can not handle different layouts.
            CBUFFER_START( UnityPerMaterial )
                half4 _Color;
            CBUFFER_END

            Varyings NormalsRenderingVertex(Attributes attributes)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(attributes);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                UNITY_SKINNED_VERTEX_COMPUTE(attributes);

                SetUpSpriteInstanceProperties();
                attributes.positionOS = UnityFlipSprite(attributes.positionOS, unity_SpriteProps.xy);
                o.positionCS = TransformObjectToHClip(attributes.positionOS);
                o.uv = attributes.uv;
                o.color = attributes.color * _Color * unity_SpriteColor;
                o.normalWS = -GetViewForwardDir();
                o.tangentWS = TransformObjectToWorldDir(attributes.tangent.xyz);
                o.bitangentWS = cross(o.normalWS, o.tangentWS) * attributes.tangent.w;
                return o;
            }

            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/NormalsRenderingShared.hlsl"

            half4 NormalsRenderingFragment(Varyings i) : SV_Target
            {
                const half4 mainTex = i.color * SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);
                const half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, i.uv));

                return NormalsRenderingShared(mainTex, normalTS, i.tangentWS.xyz, i.bitangentWS.xyz, i.normalWS.xyz);
            }
            ENDHLSL
        }

        Pass
        {
            Tags { "LightMode" = "UniversalForward" "Queue"="Transparent" "RenderType"="Transparent"}

            HLSLPROGRAM
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/2D/Include/Core2D.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/DebugMipmapStreamingMacros.hlsl"
            #if defined(DEBUG_DISPLAY)
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Debug/Debugging2D.hlsl"
            #endif

            #pragma vertex UnlitVertex
            #pragma fragment UnlitFragment

            // GPU Instancing
            #pragma multi_compile_instancing
            #pragma multi_compile _ DEBUG_DISPLAY SKINNED_SPRITE

            struct Attributes
            {
                float3 positionOS   : POSITION;
                float4 color        : COLOR;
                float2 uv           : TEXCOORD0;
                UNITY_SKINNED_VERTEX_INPUTS
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4  positionCS      : SV_POSITION;
                float4  color           : COLOR;
                float2  uv              : TEXCOORD0;
                #if defined(DEBUG_DISPLAY)
                float3  positionWS  : TEXCOORD2;
                #endif
                UNITY_VERTEX_OUTPUT_STEREO
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            UNITY_TEXTURE_STREAMING_DEBUG_VARS_FOR_TEX(_MainTex);

            // NOTE: Do not ifdef the properties here as SRP batcher can not handle different layouts.
            CBUFFER_START( UnityPerMaterial )
                half4 _Color;
            CBUFFER_END

            Varyings UnlitVertex(Attributes attributes)
            {
                Varyings o = (Varyings)0;
                UNITY_SETUP_INSTANCE_ID(attributes);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                UNITY_SKINNED_VERTEX_COMPUTE(attributes);

                SetUpSpriteInstanceProperties();
                attributes.positionOS = UnityFlipSprite( attributes.positionOS, unity_SpriteProps.xy);
                o.positionCS = TransformObjectToHClip(attributes.positionOS);
                #if defined(DEBUG_DISPLAY)
                o.positionWS = TransformObjectToWorld(attributes.positionOS);
                #endif
                o.uv = attributes.uv;
                o.color = attributes.color * _Color * unity_SpriteColor;
                return o;
            }

            float4 UnlitFragment(Varyings i) : SV_Target
            {
                float4 mainTex = i.color * SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);

                #if defined(DEBUG_DISPLAY)
                SurfaceData2D surfaceData;
                InputData2D inputData;
                half4 debugColor = 0;

                InitializeSurfaceData(mainTex.rgb, mainTex.a, surfaceData);
                InitializeInputData(i.uv, inputData);
                SETUP_DEBUG_TEXTURE_DATA_2D_NO_TS(inputData, i.positionWS, i.positionCS, _MainTex);

                if(CanDebugOverrideOutputColor(surfaceData, inputData, debugColor))
                {
                    return debugColor;
                }
                #endif

                return mainTex;
            }
            ENDHLSL
        }
    }
}
