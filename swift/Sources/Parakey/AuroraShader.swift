enum AuroraShader {
    static let source = #"""


#include <metal_stdlib>

using namespace metal;

inline half3 anchorColorAt(int i, half3 a, half3 b, half3 c, half3 d) {
  if (i == 0)  return a;
  if (i == 1)  return b;
  if (i == 2)  return c;
  if (i == 3)  return d;
  if (i == 4)  return c;
  if (i == 5)  return a;
  if (i == 6)  return b;
  if (i == 7)  return d;
  if (i == 8)  return b;
  if (i == 9)  return c;
  return a;
}

constant float2 kAnchorFreq[11] = {
  float2(0.31, 0.27), float2(0.43, 0.19), float2(0.17, 0.37),
  float2(0.29, 0.23), float2(0.41, 0.31), float2(0.19, 0.43),
  float2(0.37, 0.17), float2(0.23, 0.29), float2(0.31, 0.41),
  float2(0.27, 0.19), float2(0.43, 0.37),
};

constant float2 kAnchorPhase[11] = {
  float2(0.0, 1.7), float2(1.3, 0.4), float2(2.1, 2.6),
  float2(0.7, 1.1), float2(2.8, 0.2), float2(1.8, 2.3),
  float2(0.3, 1.5), float2(2.5, 0.8), float2(1.2, 2.0),
  float2(0.5, 1.9), float2(2.7, 0.6),
};

constant float kBurstDuration = 3.5;

inline float burstAmplitude(float t, float ampBoost, float decay) {
  if (t < 0.0 || t >= kBurstDuration) return 1.0;
  float d = exp(-t * decay);
  float wave = cos(t * 6.28318 * 1.3);
  return 1.0 + ampBoost * d * wave;
}

inline float burstSpeed(float t, float speedBoost, float decay) {
  if (t < 0.0 || t >= kBurstDuration) return 1.0;
  return 1.0 + speedBoost * exp(-t * (decay + 0.2));
}

inline float burstBrightness(float t, float pop, float decay) {
  if (t < 0.0 || t >= kBurstDuration) return 1.0;
  return 1.0 + pop * exp(-t * (decay + 1.4));
}

inline float burstFlameAmp(float t, float ampBoost, float baseline, float decay) {
  if (t < 0.0 || t >= kBurstDuration) return baseline;
  return baseline + ampBoost * exp(-t * decay);
}

inline float burstNoiseSpeed(float t, float decay) {
  if (t < 0.0 || t >= kBurstDuration) return 1.0;
  return 1.0 + 3.0 * exp(-t * (decay + 0.1));
}

inline float introScale(float t, float duration) {
  if (t < 0.0 || t >= duration) return 1.0;
  float p = t / duration;
  float ease = 1.0 - pow(1.0 - p, 3.0);
  float bump = 0.08 * sin(p * 3.14159);
  return ease * (1.0 + bump);
}

inline float introScaleHeartbeat(float t, float duration) {
  if (t < 0.0 || t >= duration) return 1.0;
  float p = t / duration;
  float base = 1.0 - pow(1.0 - p, 2.0);
  float pulses = 0.35 * exp(-p * 3.5) * cos(p * 6.28318 * 2.8);
  return clamp(base + pulses, 0.0, 1.5);
}

inline float borderFillMask(
  float2 position, float2 size, float startPerimT, float t, float duration
) {
  if (t < 0.0 || t >= duration) return 1.0;

  float2 p = position - size * 0.5;
  float angle = atan2(p.y, p.x);
  float perimT = (angle + 3.14159) * 0.15915494;

  float dist = abs(perimT - startPerimT);
  dist = min(dist, 1.0 - dist) * 2.0;

  float normT = t / duration;
  float softness = 0.08;
  return 1.0 - smoothstep(normT - softness, normT + softness, dist);
}

inline float perimeterStartFromDirection(float2 dir) {
  return (atan2(-dir.y, -dir.x) + 3.14159) * 0.15915494;
}

inline float introWashAlpha(
  float t, float2 position, float2 size, float2 direction,
  float sweepDuration, float pulseWidth, float peak
) {
  if (t < 0.0 || peak <= 0.0) return 0.0;

  float proj = dot(position, direction);
  float minProj = min(0.0, size.x * direction.x) + min(0.0, size.y * direction.y);
  float maxProj = max(0.0, size.x * direction.x) + max(0.0, size.y * direction.y);
  float range = max(maxProj - minProj, 1.0);

  float normT = (proj - minProj) / range;
  float arrival = normT * sweepDuration;
  float localT  = t - arrival;
  if (localT < 0.0 || localT > pulseWidth) return 0.0;

  float u = localT / pulseWidth;
  return peak * sin(u * 3.14159);
}

inline float3 hash33(float3 p) {
  p = float3(
             dot(p, float3(127.1, 311.7,  74.7)),
             dot(p, float3(269.5, 183.3, 246.1)),
             dot(p, float3(113.5, 271.9, 124.6))
             );
  return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

inline float gradientNoise3D(float3 p) {
  float3 i = floor(p);
  float3 f = fract(p);
  float3 u = f * f * (3.0 - 2.0 * f);

  return mix(
             mix(
                 mix(dot(hash33(i + float3(0,0,0)), f - float3(0,0,0)),
                     dot(hash33(i + float3(1,0,0)), f - float3(1,0,0)), u.x),
                 mix(dot(hash33(i + float3(0,1,0)), f - float3(0,1,0)),
                     dot(hash33(i + float3(1,1,0)), f - float3(1,1,0)), u.x),
                 u.y),
             mix(
                 mix(dot(hash33(i + float3(0,0,1)), f - float3(0,0,1)),
                     dot(hash33(i + float3(1,0,1)), f - float3(1,0,1)), u.x),
                 mix(dot(hash33(i + float3(0,1,1)), f - float3(0,1,1)),
                     dot(hash33(i + float3(1,1,1)), f - float3(1,1,1)), u.x),
                 u.y),
             u.z);
}

inline float fbm3D(float3 p) {
  float v = 0.0;
  float a = 0.6;
  v += a * gradientNoise3D(p);
  p *= 2.1;
  a *= 0.55;
  v += a * gradientNoise3D(p);
  return v;
}

inline float roundedRectSDF(float2 p, float2 halfSize, float cornerRadius) {
  float2 q = abs(p) - halfSize + cornerRadius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cornerRadius;
}

inline float2 anchorPosition(
                             int i, float time, float burstT,
                             float ampBoost, float speedBoost, float decay,
                             float2 size
                             ) {
  float ampScale   = burstAmplitude(burstT, ampBoost, decay);
  float burstTime = max(burstT, 0.0);
  float acceleration = max(decay + 0.2, 0.001);

  float2 phase = kAnchorPhase[i];
  float2 freq  = kAnchorFreq[i];

  float extra = (1.0 - exp(-burstTime * acceleration)) * speedBoost / acceleration;
  float t = time + extra;
  float amp = clamp(0.42 * ampScale, 0.0, 0.48);

  float2 norm = float2(
                       0.5 + amp * sin(t * freq.x + phase.x),
                       0.5 + amp * cos(t * freq.y + phase.y)
                       );
  return norm * size;
}

inline half3 intelligenceLightColor(
                                    float2 xyPos, float2 size,
                                    float time, float burstT,
                                    float ampBoost, float speedBoost, float decay,
                                    float reach, float power,
                                    half3 paletteBase,
                                    half3 paletteA, half3 paletteB,
                                    half3 paletteC, half3 paletteD
                                    ) {
  float radius = size.x * 0.12;
  float2 positions[3] = {xyPos, xyPos-float2(radius,0), xyPos+float2(radius,0)};
  half3 samples[3] = {paletteBase,paletteBase,paletteBase};
  for (int i = 0; i < 11; ++i) {
    float2 anchor = anchorPosition(i, time, burstT, ampBoost, speedBoost, decay, size);
    half3 anchorColor = anchorColorAt(i, paletteA, paletteB, paletteC, paletteD);
    for (int j = 0; j < 3; ++j) {
      float d = length(anchor - positions[j]) / reach;
      float fall = clamp(1.0 - d, 0.0, 1.0);
      float weight = fall * fall * (3.0 - 2.0 * fall);
      samples[j] = mix(samples[j], anchorColor, half(weight));
    }
  }
  half3 color = samples[0]*0.5h+(samples[1]+samples[2])*0.25h;
  color = min(color, half3(1.0h));

  half  luma = dot(color, half3(0.213h, 0.716h, 0.072h));
  half  satFactor = half(1.0 + power * 0.2);
  color = mix(half3(luma), color, satFactor);

  return color;
}

inline half4 auroraGlow(
                                  float2 position,
                                  half4 color,
                                  float2 size,
                                  float time,
                                  float motionTime,
                                  float cornerRadius,
                                  float edgeOffset,
                                  float borderWidth,
                                  float glowSize,
                                  float burstElapsed,
                                  float introElapsed,
                                  float outroElapsed,
                                  float2 introParams,
                                  float2 outroParams,
                                  float4 tuningA,
                                  float4 tuningB,
                                  float3 washParams,
                                  float2 washDirection,
                                  float3 paletteBase,
                                  float3 paletteA,
                                  float3 paletteB,
                                  float3 paletteC,
                                  float3 paletteD
                                  ) {
  float anchorAmpBoost   = tuningA.x;
  float anchorSpeedBoost = tuningA.y;
  float flameAmpBoost    = tuningA.z;
  float brightnessPop    = tuningA.w;
  float decayRate        = tuningB.x;
  float flameBaseline    = tuningB.y;

  float2 center = size * 0.5;
  float2 p = position - center;

  float introDuration = introParams.x;
  float styleId       = introParams.y;
  bool useBorderFill  = styleId > 0.5 && styleId < 1.5;
  bool useHeartbeat   = styleId > 1.5;

  float introMul;
  if (useBorderFill) {
    introMul = 1.0;
  } else if (useHeartbeat) {
    introMul = introScaleHeartbeat(introElapsed, introDuration);
  } else {
    introMul = introScale(introElapsed, introDuration);
  }

  float outroAlpha = 1.0;
  if (outroElapsed >= 0.0) {
    float outroDur     = outroParams.x;
    float outroStyleId = outroParams.y;
    float op = clamp(outroElapsed / max(outroDur, 0.0001), 0.0, 1.0);
    if (outroStyleId > 0.5) {
      introMul *= (1.0 - op);
    } else {
      outroAlpha = pow(1.0-op,2.2);
    }
  }

  float effectiveBorder = borderWidth * introMul;
  float effectiveGlow = glowSize * introMul;

  float2 uv = position / max(size.x, size.y);
  float noiseScrollSpeed = 0.30;
  float n  = fbm3D(float3(uv * 2.0, motionTime * noiseScrollSpeed));
  float n2 = gradientNoise3D(float3(uv * 3.6 + float2(11.7, 5.3),
                                    motionTime * noiseScrollSpeed * 0.55));
  float waveValue = n * 0.7 + n2 * 0.35;

  float cameraDistance = roundedRectSDF(p, center, cornerRadius) + 3.0;
  float screenDistance = position.y - edgeOffset;
  float join = clamp(0.5 + 0.5 * (screenDistance-cameraDistance)/6.0,0.0,1.0);
  float distRaw = mix(screenDistance,cameraDistance,join)-6.0*join*(1.0-join);
  float flameAmp = burstFlameAmp(burstElapsed, flameAmpBoost, flameBaseline, decayRate);
  float absDist = max(distRaw, 0.0);
  float haloWidth = effectiveGlow * (1.0 + clamp(waveValue * flameAmp, -0.35, 0.65));

  float softness = effectiveBorder + 2.5;
  float core = 0.17 * exp(-0.5 * absDist * absDist / (softness * softness));
  float density = 0.86+0.28*saturate(0.5+waveValue);
  float mid = 0.58*exp(-absDist/max(haloWidth*0.30,0.001))*density;
  float diffuseWidth = max(haloWidth*0.62,0.001);
  float wide = 0.32*exp(-0.5*absDist*absDist/(diffuseWidth*diffuseWidth));
  float maskIntensity = 1.0-pow(1.0-saturate(core + mid + wide),1.20);

  float flicker = 0.88 + 0.18 * (waveValue * 0.5 + 0.5);
  maskIntensity *= flicker;

  if (useBorderFill) {
    float startPerimT = perimeterStartFromDirection(washDirection);
    float fillMask = borderFillMask(position, size, startPerimT, introElapsed, introDuration);
    maskIntensity *= fillMask;
  }

  float washAlpha = introWashAlpha(
    introElapsed, position, size, washDirection,
    washParams.x, washParams.y, washParams.z
  );
  float washIntensity = washAlpha * (0.55 + 0.45 * (waveValue * 0.5 + 0.5));
  maskIntensity = max(maskIntensity, washIntensity);

  float reach = 0.55 * max(size.x, size.y);
  half3 lit = intelligenceLightColor(
                                     float2(clamp(position.x,0.0,size.x),position.y), size,
                                     time, burstElapsed,
                                     anchorAmpBoost, anchorSpeedBoost, decayRate,
                                     reach, 0.0,
                                     half3(paletteBase),
                                     half3(paletteA), half3(paletteB),
                                     half3(paletteC), half3(paletteD)
                                     );

  lit *= half(0.95 * burstBrightness(burstElapsed, brightnessPop, decayRate));

  half washLuma = dot(lit, half3(0.213h, 0.716h, 0.072h));
  half satFactor = half(1.0) + half(washAlpha) * half(0.5);
  lit = mix(half3(washLuma), lit, satFactor);

  maskIntensity *= outroAlpha;
  return half4(lit * half(maskIntensity), half(maskIntensity));
}

inline half4 auroraShimmer(
  float2 position,
  float2 size,
  float time,
  float3 paletteBase,
  float3 paletteA,
  float3 paletteB,
  float3 paletteC,
  float3 paletteD
) {

  float shimmerTime = time * 10.0;
  float reach = 0.55 * max(size.x, size.y);
  half3 lit = intelligenceLightColor(
    position, size,
    shimmerTime, -1.0,
    0.0, 0.0, 1.0,
    reach, 0.0,
    half3(paletteBase),
    half3(paletteA), half3(paletteB),
    half3(paletteC), half3(paletteD)
  );
  return half4(lit, 1.0h);
}

struct AuroraParameters {
  float2 canvas;
  float2 camera;
  float4 timing;
  float4 activity;
  float4 output;
  float4 entrance;
  float4 paletteA;
  float4 paletteB;
  float4 paletteC;
  float4 paletteD;
  float4x4 innerShapeA;
  float4x4 innerShapeB;
  float4x4 outerShapeA;
  float4x4 outerShapeB;
  float4 colorMotion;
  float4 layerVoice;
};
struct AuroraVertex {
  float4 position [[position]];
  float2 uv;
};
vertex AuroraVertex notchVertex(uint id [[vertex_id]]) {
  float2 points[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
  AuroraVertex out;
  out.position = float4(points[id],0,1);
  out.uv = float2(points[id].x*0.5+0.5,0.5-points[id].y*0.5);
  return out;
}
float membranePerimeter(float2 p,float2 size,float radius) {
  float side = max(size.y-radius-12.0,0.0);
  float quarter = M_PI_F*radius*0.5;
  float bottom = size.x-2.0*radius;
  float total = 2.0*side+2.0*quarter+bottom;
  float along;
  if (p.y <= size.y-radius) {
    float vertical = clamp(p.y-12.0,0.0,side);
    along = p.x<size.x*0.5 ? vertical : total-vertical;
  } else if (p.x<radius || p.x>size.x-radius) {
    float horizontal = max(abs(p.x-size.x*0.5)-(size.x*0.5-radius),0.0);
    float angle = atan2(max(p.y-(size.y-radius),0.0),horizontal);
    along = p.x<size.x*0.5 ? side+angle*radius
        : side+quarter+bottom+(M_PI_F*0.5-angle)*radius;
  } else {
    along = side+quarter+p.x-radius;
  }
  return clamp(along/max(total,1.0),0.0,1.0);
}
float3 membraneColor(float coordinate,constant AuroraParameters &u) {
  float f = fract(coordinate)*5.0;
  float3 colors[6];
  if (u.paletteD.w>0.5) {
    colors[0]=float3(160,111,255)/255.0;
    colors[1]=float3(250,93,219)/255.0;
    colors[2]=float3(255,79,120)/255.0;
    colors[3]=float3(255,145,61)/255.0;
    colors[4]=float3(79,158,255)/255.0;
  } else {
    colors[0]=u.paletteA.xyz;colors[1]=mix(u.paletteA.xyz,u.paletteB.xyz,0.5);
    colors[2]=u.paletteB.xyz;colors[3]=u.paletteC.xyz;colors[4]=u.paletteD.xyz;
  }
  colors[5]=colors[0];
  int index = min(int(floor(f)),4);
  float t=fract(f);
  float t2=t*t;
  float t3=t2*t;
  float w0=pow(1.0-t,3.0)/6.0;
  float w1=(3.0*t3-6.0*t2+4.0)/6.0;
  float w2=(-3.0*t3+3.0*t2+3.0*t+1.0)/6.0;
  float w3=t3/6.0;
  return colors[(index+4)%5]*w0+colors[index]*w1+colors[(index+1)%5]*w2+colors[(index+2)%5]*w3;
}
float liquidWander(float time,float seed) {
  float t = time+seed*0.371;
  float index = floor(t);
  float f = fract(t);
  float ease = f*f*f*(f*(f*6.0-15.0)+10.0);
  float a = fract(sin(index*127.1+seed*311.7)*43758.5453);
  float b = fract(sin((index+1.0)*127.1+seed*311.7)*43758.5453);
  return mix(a,b,ease);
}
float liquidCrest(float s,float time,float seed) {
  float centerA = 0.08+0.84*liquidWander(time*0.32,seed);
  float centerB = 0.08+0.84*liquidWander(time*0.23,seed+5.0);
  float widthA = 0.16+0.12*liquidWander(time*0.27,seed+11.0);
  float widthB = 0.13+0.12*liquidWander(time*0.21,seed+17.0);
  float weight = 0.35+0.30*liquidWander(time*0.19,seed+23.0);
  float a = exp(-pow((s-centerA)/widthA,2.0));
  float b = exp(-pow((s-centerB)/widthB,2.0));
  return mix(a,b,weight);
}
float membraneArrival(float age,float duration) {
  float progress=clamp(age/duration,0.0,1.0);
  return 1.0-pow(1.0-progress,3.0);
}
float membraneEase(float progress) {
  float t=clamp(progress,0.0,1.0);
  return t*t*t*(t*(t*6.0-15.0)+10.0);
}
float membranePulse(float progress) {
  return pow(sin(M_PI_F*clamp(progress,0.0,1.0)),2.0);
}
float liquidRadiusAt(int index,float4x4 a,float4x4 b) {
  int i=(index+32)%32;
  return i<16 ? a[i/4][i%4] : b[(i-16)/4][i%4];
}
float liquidRadius(float s,float4x4 a,float4x4 b) {
  float coordinate=fract(s)*32.0;
  int i=int(floor(coordinate));
  float t=fract(coordinate);
  float p0=liquidRadiusAt(i-1,a,b);
  float p1=liquidRadiusAt(i,a,b);
  float p2=liquidRadiusAt(i+1,a,b);
  float p3=liquidRadiusAt(i+2,a,b);
  return 0.5*((2.0*p1)+(-p0+p2)*t+(2.0*p0-5.0*p1+4.0*p2-p3)*t*t+(-p0+3.0*p1-3.0*p2+p3)*t*t*t);
}
constant float notchCueEnvelope[57] = {
  0.0,0.00018,0.44439,0.67859,0.67532,0.68979,0.71332,0.71264,
  0.71519,0.71028,0.71624,0.73723,0.75952,0.82502,1.0,0.96915,
  0.95403,0.93368,0.90515,0.87679,0.84985,0.82905,0.80668,0.78653,
  0.77641,0.75968,0.7277,0.69236,0.65304,0.61111,0.5673,0.52613,
  0.48908,0.45432,0.42189,0.39449,0.36825,0.3428,0.31791,0.29393,
  0.26952,0.24447,0.22479,0.20622,0.18829,0.17395,0.16122,0.14933,
  0.13886,0.13007,0.1218,0.11271,0.10336,0.09525,0.0881,0.08108,0.07455
};
float notchCueEnergy(float age) {
  if (age<0.0 || age>=0.56) return 0.0;
  float coordinate=age/0.01;
  int index=int(floor(coordinate));
  return mix(notchCueEnvelope[index],notchCueEnvelope[index+1],fract(coordinate))*(1.0-smoothstep(0.40,0.56,age));
}
fragment half4 notchAurora(AuroraVertex in [[stage_in]],constant AuroraParameters &u [[buffer(0)]]) {
  float2 size = u.camera+float2(0,12);
  float2 worldPosition = in.uv*u.canvas-float2((u.canvas.x-u.camera.x)*0.5,-12);
  float housingDistance = roundedRectSDF(worldPosition-size*0.5,size*0.5,9);
  float housingAA = max(fwidth(housingDistance),0.65);
  float housingMask = smoothstep(-housingAA,housingAA,housingDistance);
  float cameraMask = smoothstep(-3.0-housingAA,-3.0+housingAA,housingDistance);
  float entranceProgress = u.timing.z<0.0 ? 1.0 : clamp(u.timing.z/max(u.entrance.x,0.001),0.0,1.0);
  float entranceAge = entranceProgress*0.56;
  float entranceTravel = clamp(entranceAge/0.17,0.0,1.0);
  float entranceReturn = clamp(entranceAge/0.42,0.0,1.0);
  float entranceImpulse = u.activity.z>0.5 ? 0.0 : pow(entranceReturn,3.0)*pow(1.0-entranceReturn,4.0)/0.008393004;
  float entranceLight = u.activity.z>0.5 ? 0.0 : 0.45*notchCueEnergy(entranceAge);
  float entranceScale = u.activity.z>0.5 ? 1.0 : (1.0-pow(1.0-entranceTravel,3.0)*(1.0+entranceTravel))*(1.0+0.028*entranceImpulse);
  float2 entranceOrigin = float2(size.x*0.5,size.y);
  float2 position = entranceOrigin+(worldPosition-entranceOrigin)/max(entranceScale,0.001);
  float distance = roundedRectSDF(position-size*0.5,size*0.5,9);
  float edgeAA = max(fwidth(distance),0.65);
  float s = membranePerimeter(position,size,9);
  bool reduced = u.activity.z>0.5;
  float processingTime=max(u.output.w,0.0);
  float processingBlend=u.output.w>=0.0 ? smoothstep(0.0,0.24,processingTime) : 0.0;
  float busy = processingBlend;
  float voice = mix(u.activity.x,0.3,busy);
  float strength=pow(clamp(voice,0.0,1.0),0.65);
  float innerVoice=u.layerVoice.w>0.5 ? mix(u.layerVoice.x,0.3,busy) : voice;
  float outerVoice=u.layerVoice.w>0.5 ? mix(u.layerVoice.y,0.3,busy) : voice;
  float innerDrive=mix((1.0-exp(-2.2*innerVoice))/(1.0-exp(-2.2)),innerVoice,busy);
  float outerDrive=mix((1.0-exp(-2.2*outerVoice))/(1.0-exp(-2.2)),outerVoice,busy);
  float innerStrength=pow(clamp(innerDrive,0.0,1.0),0.65);
  float outerStrength=pow(clamp(outerDrive,0.0,1.0),0.65);
  float voiceSizeGain=0.80;
  float outerScale=mix(0.627,mix(1.22,1.1781153,busy),outerStrength*voiceSizeGain);
  float innerScale=mix(0.53118,mix(0.80,0.72812,busy),pow(innerStrength,0.84)*voiceSizeGain);
  bool departing=u.timing.w>=0.0;
  float innerDeparture=departing && !reduced ? membraneEase(u.timing.w/0.30) : 0.0;
  float outerDeparture=departing && !reduced ? membraneEase(max(u.timing.w-0.025,0.0)/0.335) : 0.0;
  float innerDistance=distance;
  float outerDistance=distance;
  float innerPerimeter=s;
  float outerPerimeter=s;
  float innerRadius=reduced ? 0.5 : liquidRadius(innerPerimeter,u.innerShapeA,u.innerShapeB);
  float outerRadius=reduced ? 0.5 : liquidRadius(outerPerimeter,u.outerShapeA,u.outerShapeB);
  float shape=1.0;
  float departureAlpha=!departing ? 1.0 : (reduced ? 1.0-membraneEase(u.timing.w/0.14) : 1.0-membraneEase((u.timing.w-0.28)/0.08));
  float arrivalSpark=0.0;
  float first=shape*(1.8+max(1.2,50.0*(innerScale*innerRadius*2.0-0.45)));
  float second=shape*(2.8+max(2.0,50.0*(outerScale*outerRadius*2.0-0.45)));
  first+=entranceImpulse*(5.0+0.7*cos(s*2.0*M_PI_F+0.4))*(1.0-0.75*innerStrength);
  second+=entranceImpulse*(8.0-1.0*cos(s*2.0*M_PI_F-0.5))*(1.0-0.80*outerStrength);
  first*=1.0+(u.output.w>=0.0 ? 0.06*smoothstep(0.18,0.95,processingTime) : 0.0);
  second*=1.0+(u.output.w>=0.0 ? 0.12*smoothstep(0.30,1.18,processingTime) : 0.0);
  float processingPhase=reduced ? 0.0 : processingTime*2.0*M_PI_F*0.85;
  float innerWorkingPhase=innerPerimeter*2.0*M_PI_F*1.5-processingPhase;
  float outerWorkingPhase=outerPerimeter*2.0*M_PI_F*1.5+processingPhase+1.1;
  float innerWorkingWave=(sin(innerWorkingPhase)-0.12*sin(innerWorkingPhase*3.0))/1.12;
  float outerWorkingWave=(sin(outerWorkingPhase)-0.12*sin(outerWorkingPhase*3.0))/1.12;
  first+=busy*(1.2+(reduced ? 0.0 : 2.2*innerWorkingWave));
  second+=busy*(2.0+(reduced ? 0.0 : 3.4*outerWorkingWave));
  float voiceFootprintScale=1.0-0.15*max(innerStrength,outerStrength)*(1.0-busy);
  first*=voiceFootprintScale;
  second*=voiceFootprintScale;
  first=first*(1.0-innerDeparture)-3.0*innerDeparture;
  second=second*(1.0-outerDeparture)-3.0*outerDeparture;
  float materialAlpha=0.32+strength*0.16;
  float outerCoverage=1.0-smoothstep(second-edgeAA,second+edgeAA,outerDistance);
  float innerCoverage=1.0-smoothstep(first-edgeAA,first+edgeAA,innerDistance);
  float outerFill=outerCoverage*materialAlpha;
  float innerFill=innerCoverage*materialAlpha;
  float opacity=max(innerCoverage,outerCoverage)*materialAlpha;
  if (busy>0.001) {
    float head = fract(max(u.output.w,0.0)*0.85);
    float innerArc=abs(fract(innerPerimeter-head+0.5)-0.5);
    float outerArc=abs(fract(outerPerimeter+head+0.5)-0.5);
    float shimmer = max(exp(-pow(innerArc/0.11,2.0))*innerFill,
        exp(-pow(outerArc/0.11,2.0))*outerFill);
    opacity = 1.0-(1.0-opacity)*(1.0-shimmer*busy*0.55);
  }
  float visibility=departureAlpha*cameraMask*(entranceScale>0.0 ? 1.0 : 0.0);
  if (u.output.x>1.5) {
    float outerGlass=1.0-smoothstep(second-1.0,second+1.0,outerDistance);
    float innerGlass=1.0-smoothstep(first-1.0,first+1.0,innerDistance);
    float glass=max(outerGlass,innerGlass)*0.36*visibility;
    return half4(half3(glass),half(glass));
  }
  opacity *= visibility;
  float colorPhase=reduced ? 0.0 : u.timing.x*0.085+processingBlend*(0.24*processingTime+0.08*sin(processingTime*2.1));
  float innerColorPhase=reduced ? 0.37 : u.colorMotion.x;
  float lightVoice=(1.0-exp(-4.0*clamp(voice,0.0,1.0)))/(1.0-exp(-4.0));
  float processingArc=reduced ? 0.25 : abs(fract(s-processingTime*0.85+0.5)-0.5);
  float processingLight=processingBlend*(0.38+0.50*exp(-pow(processingArc/0.18,2.0)));
  float speechLight=min(1.0,pow(lightVoice,0.65)*(1.0-busy)+processingLight);
  float voiceRadiance=pow(speechLight,1.6)+processingBlend*(0.20+0.08*sin(processingTime*2.0));
  float2 radialScale=float2(max(size.x*0.60,1.0),max(size.y*1.15,1.0));
  float2 fieldPosition=(position-float2(size.x*0.5,size.y*0.40))/radialScale;
  float fieldAngle=reduced ? 0.55 : u.output.y*0.22+0.35*sin(u.output.y*0.11);
  float2 fieldDirection=float2(cos(fieldAngle),sin(fieldAngle));
  float processingColorFlow=reduced ? 0.0 : busy*0.15*sin(s*2.0*M_PI_F-processingPhase*0.65);
  float combinedColorPhase=dot(fieldPosition,fieldDirection)*0.30+length(fieldPosition)*0.10-colorPhase+processingColorFlow;
  float3 outerColor=membraneColor(combinedColorPhase,u);
  float colorFreedom=reduced ? 0.045 : 0.035+0.020*(0.5+0.5*sin(u.output.y*0.13));
  float innerOffset=0.045+sin((innerColorPhase-colorPhase)*2.0*M_PI_F)*colorFreedom;
  innerOffset+=reduced ? 0.0 : busy*0.07*sin(s*2.0*M_PI_F+processingPhase*0.9);
  float3 innerColor=membraneColor(combinedColorPhase+innerOffset,u);
  float innerColorCrest=reduced ? 0.0 : pow(0.5+0.5*innerWorkingWave,2.0);
  float outerColorCrest=reduced ? 0.0 : pow(0.5+0.5*outerWorkingWave,2.0);
  outerColor=mix(outerColor,membraneColor(combinedColorPhase+0.22,u),busy*0.46*outerColorCrest);
  innerColor=mix(innerColor,membraneColor(combinedColorPhase+innerOffset-0.20,u),busy*0.46*innerColorCrest);
  float3 outerHazeTint=outerColor;
  float3 innerHazeTint=innerColor;
  float3 lumaWeights=float3(0.2126,0.7152,0.0722);
  outerColor=clamp(mix(float3(dot(outerColor,lumaWeights)),outerColor,1.45+speechLight*0.22+busy*0.30)*(1.19+0.32*voiceRadiance),float3(0.0),float3(1.0));
  innerColor=clamp(mix(float3(dot(innerColor,lumaWeights)),innerColor,1.45+speechLight*0.22+busy*0.30)*(1.19+0.32*voiceRadiance),float3(0.0),float3(1.0));
  outerColor=mix(outerColor,float3(1.0),0.10*voiceRadiance*(1.0-0.65*busy));
  innerColor=mix(innerColor,float3(1.0),0.10*voiceRadiance*(1.0-0.65*busy));
  outerColor=mix(outerColor,float3(1.0),arrivalSpark);
  innerColor=mix(innerColor,float3(1.0),arrivalSpark);
  if (u.activity.w>0.5) {
    outerColor=float3(1.0,0.22,0.18);
    innerColor=outerColor;
  }
  float layerMix=innerCoverage/max(max(innerCoverage,outerCoverage),0.0001);
  float innerMaterialStrength=1.0-step(0.5,u.activity.w);
  float quietSeparation=pow(1.0-strength*(1.0-busy),2.0)*innerMaterialStrength;
  float3 color=mix(outerColor,innerColor*(1.0-0.26*innerMaterialStrength-0.10*quietSeparation),layerMix);
  float surfaceDistance=min(innerDistance-first,outerDistance-second);
  float outsideBody=max(surfaceDistance,0.0);
  float bodyGlow=exp(-pow(outsideBody/(2.2+speechLight*2.0),2.0))*speechLight*(0.20+0.12*voiceRadiance)*visibility;
  opacity=1.0-(1.0-opacity)*(1.0-bodyGlow);
  float innerMaterial=innerCoverage*(0.22+strength*0.05+0.05*quietSeparation)*visibility*innerMaterialStrength;
  opacity=1.0-(1.0-opacity)*(1.0-innerMaterial);
  float innerEdge=abs(innerDistance-first);
  float outerEdge=abs(outerDistance-second);
  float nearestEdge=min(innerEdge,outerEdge);
  float rimAA=max(fwidth(distance)*0.5,0.18);
  float rimCore=(1.0-smoothstep(0.5-rimAA,0.5+rimAA,nearestEdge))*(0.86+speechLight*0.12);
  float rimHalo=exp(-pow(nearestEdge/(1.5+speechLight*1.5),2.0))*(0.09+speechLight*0.22+0.12*voiceRadiance);
  rimHalo+=entranceLight*0.10*exp(-pow(nearestEdge/2.2,2.0));
  float rim=(1.0-(1.0-rimCore)*(1.0-rimHalo))*visibility;
  float alpha=rim+opacity*(1.0-rim);
  float innerEdgeWeight=1.0/(0.25+innerEdge*innerEdge);
  float outerEdgeWeight=1.0/(0.25+outerEdge*outerEdge);
  float3 edgeBase=mix(outerColor,innerColor,innerEdgeWeight/(innerEdgeWeight+outerEdgeWeight));
  float edgeLuminance=dot(edgeBase,lumaWeights);
  float3 edgeColor=clamp(mix(float3(edgeLuminance),edgeBase,1.65+speechLight*0.08)*(1.18+speechLight*0.05),float3(0.0),float3(1.0));
  float3 surface=edgeColor*rim+color*opacity*(1.0-rim);
  float rimHighlight=(1.0-smoothstep(0.30-rimAA,0.30+rimAA,nearestEdge))*(0.28+speechLight*0.10+0.10*voiceRadiance)*visibility;
  surface=surface*(1.0-rimHighlight)+float3(rimHighlight);
  alpha=rimHighlight+alpha*(1.0-rimHighlight);
  float fogGate=smoothstep(-1.5,2.0,surfaceDistance);
  float nearFog=exp(-pow(outsideBody/(5.0+speechLight*3.0),2.0))*0.20;
  float farFog=exp(-pow(outsideBody/(9.0+speechLight*7.0),2.0))*0.08;
  float fogVariation=reduced ? 1.0 : 0.90+0.10*sin(s*2.0*M_PI_F+u.output.y*0.30);
  float softHaze=exp(-pow(outsideBody/(8.0+speechLight*2.0),2.0))*(0.055+speechLight*0.045);
  softHaze+=exp(-pow(outsideBody/(15.0+speechLight*4.0),2.0))*(0.020+speechLight*0.018);
  float fog=((nearFog+farFog)*1.12*pow(speechLight,0.9)*(1.0+speechLight*0.15)+softHaze*(1.0-busy))*fogGate*fogVariation*visibility;
  fog*=1.0+0.35*voiceRadiance;
  fog+=entranceLight*0.11*exp(-pow(outsideBody/11.0,2.0))*fogGate*visibility;
  float fogLuminance=dot(outerHazeTint,lumaWeights);
  float3 fogColor=max(mix(float3(fogLuminance),outerHazeTint,1.45),float3(0.0));
  float fogLight=pow(speechLight,1.2);
  float fogGain=1.0+0.65*fogLight;
  float fogEnergy=dot(pow(fogColor*fogGain,float3(8.0)),float3(1.0));
  fogColor=fogColor*fogGain/pow(1.0+fogEnergy,0.125);
  surface+=fogColor*fog*(1.0-alpha);
  alpha+=fog*(1.0-alpha);
  float innerOutside=max(innerDistance-first,0.0);
  float innerHazeGate=smoothstep(-0.8,1.3,innerDistance-first);
  float innerHazeWidth=3.0+2.0*speechLight;
  float innerHaze=exp(-pow(innerOutside/innerHazeWidth,2.0))*(0.045+0.12*speechLight);
  innerHaze+=exp(-pow(innerOutside/(innerHazeWidth*1.8),2.0))*(0.012+0.025*speechLight);
  innerHaze*=innerHazeGate*outerCoverage*visibility*(1.0-innerDeparture);
  float innerHazeLuminance=dot(innerHazeTint,lumaWeights);
  float3 innerHazeColor=max(mix(float3(innerHazeLuminance),innerHazeTint,1.45),float3(0.0));
  float innerHazeGain=1.0+0.65*pow(speechLight,1.2);
  float innerHazeEnergy=dot(pow(innerHazeColor*innerHazeGain,float3(8.0)),float3(1.0));
  innerHazeColor=innerHazeColor*innerHazeGain/pow(1.0+innerHazeEnergy,0.125);
  surface+=innerHazeColor*innerHaze*(1.0-alpha);
  alpha+=innerHaze*(1.0-alpha);
  float housingLineAA=max(fwidth(housingDistance)*0.5,0.18);
  float housingLineDistance=abs(housingDistance);
  float housingLineVisibility=visibility*smoothstep(0.0,0.45,entranceProgress);
  float housingLineCore=(1.0-smoothstep(1.0-housingLineAA,1.0+housingLineAA,housingLineDistance))
      *(0.86+0.12*speechLight);
  float housingLineHalo=exp(-pow(housingLineDistance/(1.5+1.5*speechLight),2.0))
      *(0.09+0.22*speechLight+0.12*voiceRadiance);
  float housingLineHaze=exp(-pow(housingLineDistance/(5.0+3.0*speechLight),2.0))
      *(0.025+0.10*speechLight+0.06*voiceRadiance);
  float housingLineGlowAlpha=(1.0-(1.0-housingLineHalo)*(1.0-housingLineHaze))*housingLineVisibility;
  surface=surface*(1.0-housingLineGlowAlpha)+edgeColor*housingLineGlowAlpha;
  alpha=housingLineGlowAlpha+alpha*(1.0-housingLineGlowAlpha);
  float housingLineAlpha=housingLineCore*housingLineVisibility;
  surface=surface*(1.0-housingLineAlpha)+edgeColor*housingLineAlpha;
  alpha=housingLineAlpha+alpha*(1.0-housingLineAlpha);
  float housingLineHighlight=(1.0-smoothstep(0.30-housingLineAA,0.30+housingLineAA,housingLineDistance))
      *(0.28+0.10*speechLight+0.10*voiceRadiance)*housingLineVisibility;
  surface=surface*(1.0-housingLineHighlight)+float3(housingLineHighlight);
  alpha=housingLineHighlight+alpha*(1.0-housingLineHighlight);
  half4 radiance = half4(half3(surface),half(alpha));
  return u.output.x>0.5 ? mix(half4(0,0,0,1),radiance,half(housingMask)) : radiance;
}

"""#
}
