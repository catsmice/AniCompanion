import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils, VRMHumanBoneName, VRMExpressionPresetName } from '@pixiv/three-vrm';

// ============================================================
// Scene Setup
// ============================================================

const canvas = document.getElementById('canvas');
const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();

// Camera: three.js uses +Z forward, VRM faces +Z after VRMUtils processing
const camera = new THREE.PerspectiveCamera(20, window.innerWidth / window.innerHeight, 0.1, 100);
camera.position.set(0, 1.0, 4.7);
let cameraLookAtY = 0.8;
camera.lookAt(0, cameraLookAtY, 0);

// Lighting
const directionalLight = new THREE.DirectionalLight(0xffffff, 2.0);
directionalLight.position.set(0, 3, 2);
directionalLight.lookAt(0, 1, 0);
scene.add(directionalLight);

const fillLight = new THREE.DirectionalLight(0xe6e6e6, 0.8);
fillLight.position.set(-2, 2, 1);
fillLight.lookAt(0, 1, 0);
scene.add(fillLight);

const ambientLight = new THREE.AmbientLight(0xffffff, 0.4);
scene.add(ambientLight);

// Handle resize
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});

// ============================================================
// State
// ============================================================

let vrm = null;
const clock = new THREE.Clock();

// Idle animation state
let idleStartTime = 0;
let nextBlinkTime = 0;
let isBlinking = false;
let blinkStartTime = 0;

// Idle animation constants (matching Swift VRMCharacterManager)
const BREATH_PERIOD = 3.5;
const BREATH_AMPLITUDE = 0.3;
const SWAY_X_PERIOD = 8.0;
const SWAY_X_AMPLITUDE = 0.03;
const SWAY_Y_PERIOD = 10.0;
const SWAY_Y_AMPLITUDE = 0.02;
const BLINK_INTERVAL_MIN = 3.0;
const BLINK_INTERVAL_MAX = 5.0;
const BLINK_DURATION = 0.15;

// Lip sync state
let targetMouthOpen = 0;
let currentMouthOpen = 0;
const MOUTH_SMOOTHING = 0.3;

// Expression state
let activeExpressions = []; // [{name, value}]

// Animation playback state
let animClip = null;        // parsed animation clip data
let animStartTime = 0;
let animIsPlaying = false;
let animBlendFromPose = {};  // boneName -> Quaternion (pose at animation start)
let animBoneNames = new Set(); // all bone names in current clip
const ANIM_BLEND_IN = 0.25;

// Rest pose rotations: move arms down from T-pose to natural A-pose
// Stored as {boneName: Quaternion} after applyRestPose()
const restPoseRotations = {};

function applyRestPose() {
    if (!vrm) return;

    const armAngle = 65.0 * Math.PI / 180.0;
    const forearmAngle = 10.0 * Math.PI / 180.0;

    const poses = [
        [VRMHumanBoneName.LeftUpperArm,  new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), armAngle)],
        [VRMHumanBoneName.RightUpperArm, new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), -armAngle)],
        [VRMHumanBoneName.LeftLowerArm,  new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), forearmAngle)],
        [VRMHumanBoneName.RightLowerArm, new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), -forearmAngle)],
    ];

    for (const [boneName, quat] of poses) {
        const node = vrm.humanoid.getNormalizedBoneNode(boneName);
        if (node) {
            node.quaternion.copy(quat);
            restPoseRotations[boneName] = quat.clone();
        }
    }
}

function restoreBoneToRestPose(vrmBoneName) {
    const node = vrm.humanoid.getNormalizedBoneNode(vrmBoneName);
    if (!node) return;
    const rest = restPoseRotations[vrmBoneName];
    if (rest) {
        node.quaternion.copy(rest);
    } else {
        node.quaternion.identity();
    }
}

// ============================================================
// Bone name mapping: our JSON uses standard VRM humanoid bone names → three-vrm VRMHumanBoneName
// ============================================================

const BONE_NAME_MAP = {
    'hips': VRMHumanBoneName.Hips,
    'spine': VRMHumanBoneName.Spine,
    'chest': VRMHumanBoneName.Chest,
    'upperChest': VRMHumanBoneName.UpperChest,
    'neck': VRMHumanBoneName.Neck,
    'head': VRMHumanBoneName.Head,
    'leftShoulder': VRMHumanBoneName.LeftShoulder,
    'leftUpperArm': VRMHumanBoneName.LeftUpperArm,
    'leftLowerArm': VRMHumanBoneName.LeftLowerArm,
    'leftHand': VRMHumanBoneName.LeftHand,
    'rightShoulder': VRMHumanBoneName.RightShoulder,
    'rightUpperArm': VRMHumanBoneName.RightUpperArm,
    'rightLowerArm': VRMHumanBoneName.RightLowerArm,
    'rightHand': VRMHumanBoneName.RightHand,
    'leftUpperLeg': VRMHumanBoneName.LeftUpperLeg,
    'leftLowerLeg': VRMHumanBoneName.LeftLowerLeg,
    'leftFoot': VRMHumanBoneName.LeftFoot,
    'leftToes': VRMHumanBoneName.LeftToes,
    'rightUpperLeg': VRMHumanBoneName.RightUpperLeg,
    'rightLowerLeg': VRMHumanBoneName.RightLowerLeg,
    'rightFoot': VRMHumanBoneName.RightFoot,
    'rightToes': VRMHumanBoneName.RightToes,
    'leftEye': VRMHumanBoneName.LeftEye,
    'rightEye': VRMHumanBoneName.RightEye,
    'jaw': VRMHumanBoneName.Jaw,
    'leftThumbMetacarpal': VRMHumanBoneName.LeftThumbMetacarpal,
    'leftThumbProximal': VRMHumanBoneName.LeftThumbProximal,
    'leftIndexProximal': VRMHumanBoneName.LeftIndexProximal,
    'leftIndexIntermediate': VRMHumanBoneName.LeftIndexIntermediate,
    'leftIndexDistal': VRMHumanBoneName.LeftIndexDistal,
    'leftMiddleProximal': VRMHumanBoneName.LeftMiddleProximal,
    'leftMiddleIntermediate': VRMHumanBoneName.LeftMiddleIntermediate,
    'leftMiddleDistal': VRMHumanBoneName.LeftMiddleDistal,
    'leftRingProximal': VRMHumanBoneName.LeftRingProximal,
    'leftRingIntermediate': VRMHumanBoneName.LeftRingIntermediate,
    'leftRingDistal': VRMHumanBoneName.LeftRingDistal,
    'leftLittleProximal': VRMHumanBoneName.LeftLittleProximal,
    'leftLittleIntermediate': VRMHumanBoneName.LeftLittleIntermediate,
    'leftLittleDistal': VRMHumanBoneName.LeftLittleDistal,
    'rightThumbMetacarpal': VRMHumanBoneName.RightThumbMetacarpal,
    'rightThumbProximal': VRMHumanBoneName.RightThumbProximal,
    'rightIndexProximal': VRMHumanBoneName.RightIndexProximal,
    'rightIndexIntermediate': VRMHumanBoneName.RightIndexIntermediate,
    'rightIndexDistal': VRMHumanBoneName.RightIndexDistal,
    'rightMiddleProximal': VRMHumanBoneName.RightMiddleProximal,
    'rightMiddleIntermediate': VRMHumanBoneName.RightMiddleIntermediate,
    'rightMiddleDistal': VRMHumanBoneName.RightMiddleDistal,
    'rightRingProximal': VRMHumanBoneName.RightRingProximal,
    'rightRingIntermediate': VRMHumanBoneName.RightRingIntermediate,
    'rightRingDistal': VRMHumanBoneName.RightRingDistal,
    'rightLittleProximal': VRMHumanBoneName.RightLittleProximal,
    'rightLittleIntermediate': VRMHumanBoneName.RightLittleIntermediate,
    'rightLittleDistal': VRMHumanBoneName.RightLittleDistal,
};

// ============================================================
// Helper: post message to Swift bridge
// ============================================================

function postBridge(eventName, payload) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
        window.webkit.messageHandlers.bridge.postMessage({ event: eventName, ...payload });
    }
}

// ============================================================
// VRM Loading
// ============================================================

window.loadVRM = function(url) {
    const loader = new GLTFLoader();
    loader.register((parser) => new VRMLoaderPlugin(parser));

    loader.load(
        url,
        (gltf) => {
            const loadedVRM = gltf.userData.vrm;
            if (!loadedVRM) {
                console.error('[VRM] No VRM data in GLTF');
                postBridge('modelLoaded', { success: false });
                return;
            }

            // Remove previous model
            if (vrm) {
                scene.remove(vrm.scene);
                VRMUtils.deepDispose(vrm.scene);
            }

            vrm = loadedVRM;

            // Rotate VRM 0.x models so they face the camera
            VRMUtils.rotateVRM0(vrm);

            scene.add(vrm.scene);

            // Apply rest pose (arms down from T-pose)
            applyRestPose();

            // Initialize idle state
            idleStartTime = performance.now() / 1000;
            nextBlinkTime = idleStartTime + randomBlinkInterval();

            console.log('[VRM] Model loaded successfully');
            postBridge('modelLoaded', { success: true });
        },
        (progress) => {
            // Loading progress
        },
        (error) => {
            console.error('[VRM] Failed to load:', error);
            postBridge('modelLoaded', { success: false });
        }
    );
};

// ============================================================
// Expressions
// ============================================================

window.setExpression = function(mappingsJSON) {
    if (!vrm) return;

    const mappings = typeof mappingsJSON === 'string' ? JSON.parse(mappingsJSON) : mappingsJSON;

    // Reset previous expressions
    for (const expr of activeExpressions) {
        vrm.expressionManager.setValue(expr.name, 0);
    }

    // Apply new expressions
    activeExpressions = [];
    for (const mapping of mappings) {
        vrm.expressionManager.setValue(mapping.name, mapping.value);
        activeExpressions.push(mapping);
    }
};

// ============================================================
// Lip Sync
// ============================================================

window.setMouthOpen = function(value) {
    targetMouthOpen = value;
};

window.playIdleAnimation = function() {
    targetMouthOpen = 0;
    currentMouthOpen = 0;
    if (vrm) {
        vrm.expressionManager.setValue('jawOpen', 0);
        vrm.expressionManager.setValue('aa', 0);
    }
};

// ============================================================
// Animation Playback
// ============================================================

window.playAnimation = function(clipJSON) {
    if (!vrm) return;

    const clip = typeof clipJSON === 'string' ? JSON.parse(clipJSON) : clipJSON;
    animClip = clip;
    animStartTime = performance.now() / 1000;
    animIsPlaying = true;

    // Capture current bone poses for blend-in
    animBlendFromPose = {};
    animBoneNames = new Set();
    for (const frame of clip.frames) {
        for (const boneName of Object.keys(frame.bones)) {
            animBoneNames.add(boneName);
        }
    }
    for (const boneName of animBoneNames) {
        const vrmBoneName = BONE_NAME_MAP[boneName];
        if (!vrmBoneName) continue;
        const node = vrm.humanoid.getNormalizedBoneNode(vrmBoneName);
        if (node) {
            animBlendFromPose[boneName] = node.quaternion.clone();
        }
    }
};

window.stopAnimation = function() {
    if (!vrm || !animIsPlaying) return;

    // Restore rest pose for all animated bones
    if (animClip) {
        const allBoneNames = new Set();
        for (const frame of animClip.frames) {
            for (const boneName of Object.keys(frame.bones)) {
                allBoneNames.add(boneName);
            }
        }
        for (const boneName of allBoneNames) {
            const vrmBoneName = BONE_NAME_MAP[boneName];
            if (!vrmBoneName) continue;
            restoreBoneToRestPose(vrmBoneName);
        }
    }

    animClip = null;
    animIsPlaying = false;
    animBoneNames = new Set();
};

// ============================================================
// Animation Sampling (ported from Swift AnimationPlayer)
// ============================================================

function sampleAnimation(now) {
    if (!animClip || !animIsPlaying || !vrm) return null;

    let elapsed = now - animStartTime;

    // Handle end of animation
    if (elapsed >= animClip.duration) {
        if (animClip.loop) {
            elapsed = elapsed % animClip.duration;
        } else {
            // One-shot finished — restore rest pose for animated bones
            for (const boneName of animBoneNames) {
                const vrmBoneName = BONE_NAME_MAP[boneName];
                if (vrmBoneName) restoreBoneToRestPose(vrmBoneName);
            }
            const clipName = animClip.name;
            animClip = null;
            animIsPlaying = false;
            animBoneNames = new Set();
            postBridge('animationEnded', { name: clipName });
            return null;
        }
    }

    const frames = animClip.frames;
    if (frames.length === 0) return null;

    // Binary search for keyframe at or before elapsed
    let lo = 0;
    let hi = frames.length - 1;
    while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (frames[mid].time <= elapsed) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    const frameA = frames[lo];
    const frameB = (lo + 1 < frames.length) ? frames[lo + 1] : frameA;

    // Interpolation factor
    let t = 0;
    if (frameA.time < frameB.time) {
        t = (elapsed - frameA.time) / (frameB.time - frameA.time);
    }

    // Collect all bone names from both frames
    const boneNames = new Set([...Object.keys(frameA.bones), ...Object.keys(frameB.bones)]);

    // Blend-in factor
    const blendElapsed = now - animStartTime;
    const blendFactor = Math.min(blendElapsed / ANIM_BLEND_IN, 1.0);

    const quatA = new THREE.Quaternion();
    const quatB = new THREE.Quaternion();
    const quatResult = new THREE.Quaternion();
    const quatFrom = new THREE.Quaternion();

    for (const boneName of boneNames) {
        const vrmBoneName = BONE_NAME_MAP[boneName];
        if (!vrmBoneName) continue;

        const node = vrm.humanoid.getNormalizedBoneNode(vrmBoneName);
        if (!node) continue;

        // Get keyframe quaternions [x, y, z, w]
        const aArr = frameA.bones[boneName] || [0, 0, 0, 1];
        const bArr = frameB.bones[boneName] || [0, 0, 0, 1];

        quatA.set(aArr[0], aArr[1], aArr[2], aArr[3]);
        quatB.set(bArr[0], bArr[1], bArr[2], bArr[3]);

        quatResult.slerpQuaternions(quatA, quatB, t);

        // Apply blend-in from previous pose
        if (blendFactor < 1.0 && animBlendFromPose[boneName]) {
            quatFrom.copy(animBlendFromPose[boneName]);
            quatResult.slerpQuaternions(quatFrom, quatResult, blendFactor);
        }

        node.quaternion.copy(quatResult);
    }

    return boneNames;
}

// ============================================================
// Idle Animations
// ============================================================

function randomBlinkInterval() {
    return BLINK_INTERVAL_MIN + Math.random() * (BLINK_INTERVAL_MAX - BLINK_INTERVAL_MIN);
}

function updateIdle(now, animatedBones) {
    if (!vrm) return;

    // --- Breathing ---
    if (!animatedBones || !animatedBones.has('spine')) {
        const breathPhase = ((now - idleStartTime) / BREATH_PERIOD) * 2.0 * Math.PI;
        const breathValue = (Math.sin(breathPhase) + 1.0) / 2.0 * BREATH_AMPLITUDE;
        const spineNode = vrm.humanoid.getNormalizedBoneNode(VRMHumanBoneName.Spine);
        if (spineNode) {
            spineNode.quaternion.setFromAxisAngle(new THREE.Vector3(1, 0, 0), breathValue * 0.01);
        }
    }

    // --- Head sway ---
    if (!animatedBones || !animatedBones.has('head')) {
        const swayXPhase = ((now - idleStartTime) / SWAY_X_PERIOD) * 2.0 * Math.PI;
        const swayYPhase = ((now - idleStartTime) / SWAY_Y_PERIOD) * 2.0 * Math.PI;
        const angleX = Math.sin(swayXPhase) * SWAY_X_AMPLITUDE;
        const angleY = Math.cos(swayYPhase) * SWAY_Y_AMPLITUDE;
        const headNode = vrm.humanoid.getNormalizedBoneNode(VRMHumanBoneName.Head);
        if (headNode) {
            const qx = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), angleY);
            const qz = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), angleX);
            headNode.quaternion.multiplyQuaternions(qx, qz);
        }
    }

    // --- Blink ---
    updateBlink(now);
}

function updateBlink(now) {
    if (!vrm) return;

    if (isBlinking) {
        const blinkElapsed = now - blinkStartTime;
        if (blinkElapsed >= BLINK_DURATION) {
            vrm.expressionManager.setValue(VRMExpressionPresetName.Blink, 0);
            isBlinking = false;
            nextBlinkTime = now + randomBlinkInterval();
        } else {
            const halfDuration = BLINK_DURATION / 2.0;
            let blinkWeight;
            if (blinkElapsed < halfDuration) {
                blinkWeight = blinkElapsed / halfDuration;
            } else {
                blinkWeight = 1.0 - (blinkElapsed - halfDuration) / halfDuration;
            }
            vrm.expressionManager.setValue(VRMExpressionPresetName.Blink, blinkWeight);
        }
    } else if (now >= nextBlinkTime) {
        isBlinking = true;
        blinkStartTime = now;
    }
}

// ============================================================
// Lip Sync Update
// ============================================================

function updateLipSync() {
    if (!vrm) return;

    // Smooth toward target
    currentMouthOpen = currentMouthOpen * MOUTH_SMOOTHING + targetMouthOpen * (1.0 - MOUTH_SMOOTHING);

    // Apply to expressions.
    // `aa` (the mouth-open viseme) exists on every standard VRM, so it is the primary
    // lip-sync channel. `jawOpen` only exists on ARKit / VRM 1.0 PerfectSync models
    // (the default Alicia Solid model has no jawOpen) — three-vrm ignores it harmlessly
    // when absent, and it adds extra jaw motion on models that do define it.
    vrm.expressionManager.setValue('aa', currentMouthOpen * 0.85);
    vrm.expressionManager.setValue('jawOpen', currentMouthOpen);
}

// ============================================================
// Camera Controls
// ============================================================

const CAM_STEP = 0.1;

function updateCameraLookAt() {
    camera.lookAt(camera.position.x, cameraLookAtY, 0);
}

window.moveCameraUp = function() {
    camera.position.y += CAM_STEP;
    cameraLookAtY += CAM_STEP;
    updateCameraLookAt();
};

window.moveCameraDown = function() {
    camera.position.y -= CAM_STEP;
    cameraLookAtY -= CAM_STEP;
    updateCameraLookAt();
};

window.moveCameraLeft = function() {
    camera.position.x -= CAM_STEP;
    updateCameraLookAt();
};

window.moveCameraRight = function() {
    camera.position.x += CAM_STEP;
    updateCameraLookAt();
};

window.moveCameraIn = function() {
    camera.position.z -= CAM_STEP;
    updateCameraLookAt();
};

window.moveCameraOut = function() {
    camera.position.z += CAM_STEP;
    updateCameraLookAt();
};

window.cameraLookUp = function() {
    cameraLookAtY += CAM_STEP;
    updateCameraLookAt();
};

window.cameraLookDown = function() {
    cameraLookAtY -= CAM_STEP;
    updateCameraLookAt();
};

window.getCameraState = function() {
    return JSON.stringify({
        x: Math.round(camera.position.x * 10) / 10,
        y: Math.round(camera.position.y * 10) / 10,
        z: Math.round(camera.position.z * 10) / 10,
        lookAtY: Math.round(cameraLookAtY * 10) / 10
    });
};

// ============================================================
// Render Loop
// ============================================================

function animate() {
    requestAnimationFrame(animate);

    const delta = clock.getDelta();
    const now = performance.now() / 1000;

    if (vrm) {
        // Sample and apply skeletal animation (if playing)
        const animatedBones = sampleAnimation(now);

        // Idle animations (skip bones controlled by animation)
        updateIdle(now, animatedBones);

        // Lip sync
        updateLipSync();

        // Update VRM (spring bones, expression smoothing)
        vrm.update(delta);
    }

    renderer.render(scene, camera);
}

animate();
