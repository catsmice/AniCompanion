"""
Blender script to export retargeted animations as JSON keyframe data
for AniCompanion's VRM animation system.

Supports skeletons from: Perula VRM/FBX, Mixamo, Reallusion (CC_Base), or VRM-native bone names.

Usage:
  1. Import Perula FBX into Blender (target armature)
  2. Import FBX animation (Mixamo or Reallusion, skeleton only)
  3. Retarget source bones to Perula armature (Auto-Rig Pro Remap)
  4. Select the Perula armature (must be active object)
  5. Run this script in Blender's scripting workspace

Output directory:
  Set the ANICOMPANION_ANIM_OUTPUT environment variable to choose where the
  JSON clip is written, e.g.

    ANICOMPANION_ANIM_OUTPUT=/path/to/AniCompanion/Resources/Animations \
      blender file.blend --background --python Tools/export_animation.py

  If unset, the clip is written next to the open .blend file.

The script computes each bone's deformation (rotation change from rest pose
to animated pose) in glTF Y-up space using BLENDER_TO_GLTF conversion, then
derives local rotations using the VRM bone hierarchy — producing output
compatible with VRMKit's identity-rest-pose convention.

Blender Python API: bpy, mathutils
"""

import bpy
import json
import os
from mathutils import Matrix, Quaternion

# ── Coordinate Conversion ──────────────────────────────────────────

# Blender Z-up to glTF Y-up conversion matrix.
# Maps: (x, y, z)_blender → (x, z, -y)_gltf
BLENDER_TO_GLTF = Matrix((
    (1, 0, 0, 0),
    (0, 0, 1, 0),
    (0, -1, 0, 0),
    (0, 0, 0, 1),
))

GLTF_TO_BLENDER = BLENDER_TO_GLTF.inverted()

# ── Bone Name Mappings ──────────────────────────────────────────────

# Perula VRM/FBX bone name → VRM Humanoid.Bones raw value
# (Extracted from PerulaVRM_PerfectSync.vrm humanBones mapping)
PERULA_BONE_MAP = {
    # Body
    "Hips": "hips",
    "Spine": "spine",
    "Chest": "upperChest",
    "Neck": "neck",
    "Head": "head",
    # Arms
    "Left shoulder": "leftShoulder",
    "Left arm": "leftUpperArm",
    "Left elbow": "leftLowerArm",
    "Left wrist": "leftHand",
    "Right shoulder": "rightShoulder",
    "Right arm": "rightUpperArm",
    "Right elbow": "rightLowerArm",
    "Right wrist": "rightHand",
    # Legs
    "Left leg": "leftUpperLeg",
    "Left knee": "leftLowerLeg",
    "Left ankle": "leftFoot",
    "Left toe": "leftToes",
    "Right leg": "rightUpperLeg",
    "Right knee": "rightLowerLeg",
    "Right ankle": "rightFoot",
    "Right toe": "rightToes",
    # Eyes
    "Eye_L": "leftEye",
    "Eye_R": "rightEye",
    # Left hand fingers
    "Thumb_Proximal_L": "leftThumbProximal",
    "Thumb_Intermediate_L": "leftThumbIntermediate",
    "Thumb_Distal_L": "leftThumbDistal",
    "Index_Proximal_L": "leftIndexProximal",
    "Index_Intermediate_L": "leftIndexIntermediate",
    "Index_Distal_L": "leftIndexDistal",
    "Middle_Proximal_L": "leftMiddleProximal",
    "Middle_Intermediate_L": "leftMiddleIntermediate",
    "Middle_Distal_L": "leftMiddleDistal",
    "Ring_Proximal_L": "leftRingProximal",
    "Ring_Intermediate_L": "leftRingIntermediate",
    "Ring_Distal_L": "leftRingDistal",
    "Little_Proximal_L": "leftLittleProximal",
    "Little_Intermediate_L": "leftLittleIntermediate",
    "Little_Distal_L": "leftLittleDistal",
    # Right hand fingers
    "Thumb_Proximal_R": "rightThumbProximal",
    "Thumb_Intermediate_R": "rightThumbIntermediate",
    "Thumb_Distal_R": "rightThumbDistal",
    "Index_Proximal_R": "rightIndexProximal",
    "Index_Intermediate_R": "rightIndexIntermediate",
    "Index_Distal_R": "rightIndexDistal",
    "Middle_Proximal_R": "rightMiddleProximal",
    "Middle_Intermediate_R": "rightMiddleIntermediate",
    "Middle_Distal_R": "rightMiddleDistal",
    "Ring_Proximal_R": "rightRingProximal",
    "Ring_Intermediate_R": "rightRingIntermediate",
    "Ring_Distal_R": "rightRingDistal",
    "Little_Proximal_R": "rightLittleProximal",
    "Little_Intermediate_R": "rightLittleIntermediate",
    "Little_Distal_R": "rightLittleDistal",
}

# Mixamo bone name → VRM Humanoid.Bones raw value
MIXAMO_BONE_MAP = {
    "mixamorig:Hips": "hips",
    "mixamorig:Spine": "spine",
    "mixamorig:Spine1": "spine",
    "mixamorig:Spine2": "upperChest",
    "mixamorig:Neck": "neck",
    "mixamorig:Head": "head",
    "mixamorig:LeftShoulder": "leftShoulder",
    "mixamorig:LeftArm": "leftUpperArm",
    "mixamorig:LeftForeArm": "leftLowerArm",
    "mixamorig:LeftHand": "leftHand",
    "mixamorig:RightShoulder": "rightShoulder",
    "mixamorig:RightArm": "rightUpperArm",
    "mixamorig:RightForeArm": "rightLowerArm",
    "mixamorig:RightHand": "rightHand",
    "mixamorig:LeftUpLeg": "leftUpperLeg",
    "mixamorig:LeftLeg": "leftLowerLeg",
    "mixamorig:LeftFoot": "leftFoot",
    "mixamorig:LeftToeBase": "leftToes",
    "mixamorig:RightUpLeg": "rightUpperLeg",
    "mixamorig:RightLeg": "rightLowerLeg",
    "mixamorig:RightFoot": "rightFoot",
    "mixamorig:RightToeBase": "rightToes",
}

# Reallusion Character Creator (CC_Base_*) bone name → VRM Humanoid.Bones raw value
CC_BASE_BONE_MAP = {
    "CC_Base_Hip": "hips",
    "CC_Base_Waist": "spine",
    "CC_Base_Spine01": "spine",
    "CC_Base_Spine02": "upperChest",
    "CC_Base_NeckTwist01": "neck",
    "CC_Base_NeckTwist02": "neck",
    "CC_Base_Head": "head",
    "CC_Base_L_Clavicle": "leftShoulder",
    "CC_Base_L_Upperarm": "leftUpperArm",
    "CC_Base_L_Forearm": "leftLowerArm",
    "CC_Base_L_Hand": "leftHand",
    "CC_Base_R_Clavicle": "rightShoulder",
    "CC_Base_R_Upperarm": "rightUpperArm",
    "CC_Base_R_Forearm": "rightLowerArm",
    "CC_Base_R_Hand": "rightHand",
    "CC_Base_L_Thigh": "leftUpperLeg",
    "CC_Base_L_Calf": "leftLowerLeg",
    "CC_Base_L_Foot": "leftFoot",
    "CC_Base_L_ToeBase": "leftToes",
    "CC_Base_R_Thigh": "rightUpperLeg",
    "CC_Base_R_Calf": "rightLowerLeg",
    "CC_Base_R_Foot": "rightFoot",
    "CC_Base_R_ToeBase": "rightToes",
}

# VRM-native names (identity mapping, for already-retargeted armatures)
VRM_BONE_NAMES = {
    "hips", "spine", "upperChest", "neck", "head",
    "leftShoulder", "leftUpperArm", "leftLowerArm", "leftHand",
    "rightShoulder", "rightUpperArm", "rightLowerArm", "rightHand",
    "leftUpperLeg", "leftLowerLeg", "leftFoot", "leftToes",
    "rightUpperLeg", "rightLowerLeg", "rightFoot", "rightToes",
}


def detect_and_map_bones(armature):
    """
    Auto-detect the skeleton naming convention and return a mapping
    of {blender_bone_name: vrm_bone_name} for all matched bones.
    """
    bone_names = {b.name for b in armature.pose.bones}

    # Try Perula FBX first (human-readable English names with spaces).
    perula_matches = {k: v for k, v in PERULA_BONE_MAP.items() if k in bone_names}
    if len(perula_matches) >= 5:
        print(f"Detected Perula/VRoid skeleton ({len(perula_matches)} bones matched)")
        return perula_matches

    # Try Mixamo.
    mixamo_matches = {k: v for k, v in MIXAMO_BONE_MAP.items() if k in bone_names}
    if len(mixamo_matches) >= 5:
        print(f"Detected Mixamo skeleton ({len(mixamo_matches)} bones matched)")
        return mixamo_matches

    # Try Reallusion CC_Base.
    cc_matches = {k: v for k, v in CC_BASE_BONE_MAP.items() if k in bone_names}
    if len(cc_matches) >= 5:
        print(f"Detected Reallusion CC_Base skeleton ({len(cc_matches)} bones matched)")
        return cc_matches

    # Try VRM-native names.
    vrm_matches = {n: n for n in VRM_BONE_NAMES if n in bone_names}
    if len(vrm_matches) >= 5:
        print(f"Detected VRM-native skeleton ({len(vrm_matches)} bones matched)")
        return vrm_matches

    print("WARNING: Could not auto-detect skeleton convention.")
    print(f"  Armature bones: {sorted(bone_names)[:20]}...")
    print("  Add a mapping for this skeleton in the script.")
    return {}


def find_vrm_parent(pose_bone, bone_map):
    """
    Walk up the Blender bone hierarchy to find the nearest ancestor
    that is in the bone mapping. Returns the VRM name of the parent,
    or None if this is a root bone.
    """
    parent = pose_bone.parent
    while parent:
        if parent.name in bone_map:
            return bone_map[parent.name]
        parent = parent.parent
    return None


def compute_deformation(pose_bone):
    """
    Compute a bone's deformation quaternion in armature-local space (Z-up).

    deformation = anim_rot @ rest_rot^{-1}

    No coordinate conversion here — we keep everything in Z-up so that
    quaternion multiplication (right-handed) stays correct for the
    parent-child local derivation. The Y↔Z swap to glTF Y-up is applied
    AFTER computing local rotations.
    """
    anim_q = pose_bone.matrix.to_quaternion()
    rest_q = pose_bone.bone.matrix_local.to_quaternion()
    return anim_q @ rest_q.inverted()


def armature_to_gltf(q):
    """
    Convert a local rotation quaternion from Blender armature space to
    glTF/VRM space, accounting for both the up-axis change (Z→Y) and
    the character facing direction change (-Y in Blender → -Z in VRM).

    Mapping: (qx, qy, qz) → (-qx, qz, qy)

    This is a proper rotation (det=+1, preserves handedness):
    - Blender X (character left=+X) → VRM -X (character left=-X)
    - Blender Y (forward=-Y) → VRM Z (forward=-Z)
    - Blender Z (up=+Z) → VRM Y (up=+Y)
    """
    return Quaternion((q.w, -q.x, q.z, q.y))


# Leg/foot bones — exclude for upper-body-only animations (idle, talk, etc.)
LOWER_BODY_BONES = {
    "hips", "leftUpperLeg", "leftLowerLeg", "leftFoot", "leftToes",
    "rightUpperLeg", "rightLowerLeg", "rightFoot", "rightToes",
}


def export_animation(
    clip_name="animation",
    fps=30,
    loop=False,
    output_dir=None,
    exclude_bones=None,
):
    """
    Export the active armature's animation as a JSON keyframe file.

    Bone rotations are exported in glTF coordinate space (Y-up) as local
    rotations relative to the parent bone — matching VRMKit/RealityKit's
    convention for node.transform.rotation.

    Args:
        clip_name: Name for the animation clip.
        fps: Target FPS for the export (keyframes are sampled at this rate).
        loop: Whether this animation should loop.
        output_dir: Directory to write the JSON file. Defaults to blend file dir.
        exclude_bones: Set of VRM bone names to exclude from the export.
    """
    armature = bpy.context.active_object
    if armature is None or armature.type != 'ARMATURE':
        print("ERROR: Select an armature object first.")
        return

    action = armature.animation_data and armature.animation_data.action
    if action is None:
        print("ERROR: Armature has no active action (animation).")
        return

    scene = bpy.context.scene
    frame_start = int(action.frame_range[0])
    frame_end = int(action.frame_range[1])
    scene_fps = scene.render.fps

    # Calculate frame step for target FPS.
    frame_step = max(1, round(scene_fps / fps))
    duration = (frame_end - frame_start) / scene_fps

    print(f"Exporting '{clip_name}': frames {frame_start}-{frame_end}, "
          f"scene FPS={scene_fps}, target FPS={fps}, duration={duration:.2f}s")

    # Auto-detect skeleton and build bone mapping.
    mapped_bones = detect_and_map_bones(armature)
    if not mapped_bones:
        print("ERROR: No bones could be mapped. Aborting export.")
        return

    # Filter out excluded bones.
    if exclude_bones:
        before = len(mapped_bones)
        mapped_bones = {k: v for k, v in mapped_bones.items() if v not in exclude_bones}
        print(f"Excluded {before - len(mapped_bones)} bones: {sorted(exclude_bones)}")

    print(f"Mapped {len(mapped_bones)} bones: {sorted(set(mapped_bones.values()))}")

    # Build VRM parent map: vrm_name -> vrm_parent_name (or None for root).
    vrm_parent_map = {}
    for blender_name, vrm_name in mapped_bones.items():
        pose_bone = armature.pose.bones.get(blender_name)
        if pose_bone:
            vrm_parent_map[vrm_name] = find_vrm_parent(pose_bone, mapped_bones)

    print(f"VRM hierarchy (sample): "
          f"hips<-{vrm_parent_map.get('hips')}, "
          f"spine<-{vrm_parent_map.get('spine')}, "
          f"leftUpperArm<-{vrm_parent_map.get('leftUpperArm')}")

    # Check for unmapped parent bones above mapped roots.
    for blender_name, vrm_name in mapped_bones.items():
        pose_bone = armature.pose.bones.get(blender_name)
        if pose_bone and pose_bone.parent and pose_bone.parent.name not in mapped_bones:
            print(f"  NOTE: '{vrm_name}' (Blender: '{blender_name}') has unmapped "
                  f"parent '{pose_bone.parent.name}' — will subtract parent deformation")

    # Debug: print diagnostic for leftUpperArm at first frame.
    debug_bone_name = None
    for bn, vn in mapped_bones.items():
        if vn == "leftUpperArm":
            debug_bone_name = bn
            break

    if debug_bone_name:
        bpy.context.scene.frame_set(frame_start)
        bpy.context.view_layer.update()
        db = armature.pose.bones[debug_bone_name]

        arm_w = armature.matrix_world
        print(f"\n=== DEBUG: {debug_bone_name} → leftUpperArm ===")
        print(f"armature.matrix_world 3x3:")
        for row in arm_w.to_3x3():
            print(f"  [{row[0]:7.4f}, {row[1]:7.4f}, {row[2]:7.4f}]")

        combined = BLENDER_TO_GLTF @ arm_w
        combined_q = combined.to_quaternion()
        print(f"BLENDER_TO_GLTF @ matrix_world quaternion: "
              f"({combined_q.x:.4f}, {combined_q.y:.4f}, {combined_q.z:.4f}, {combined_q.w:.4f})")
        print(f"  angle = {combined_q.angle * 180 / 3.14159:.1f}°  "
              f"(0° = identity, 180° = double rotation bug)")

        # Armature-local deformation
        deform_q = compute_deformation(db)
        gltf_q = armature_to_gltf(deform_q)
        print(f"\nArmature-local deformation:")
        print(f"  raw   = ({deform_q.x:.4f}, {deform_q.y:.4f}, {deform_q.z:.4f}, {deform_q.w:.4f})")
        print(f"  glTF  = ({gltf_q.x:.4f}, {gltf_q.y:.4f}, {gltf_q.z:.4f}, {gltf_q.w:.4f})")
        print(f"=== END DEBUG ===\n")

    # Sample keyframes.
    frames = []
    for frame in range(frame_start, frame_end + 1, frame_step):
        # Set frame once, then sample all bones.
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()

        time = round((frame - frame_start) / scene_fps, 4)

        # Step 1: Compute deformation for each bone in armature-local space (Z-up).
        # Also compute deformation for unmapped parent bones (e.g. root/motion
        # bone above hips) so we can derive correct locals.
        deformations = {}
        unmapped_deformations = {}
        for blender_name, vrm_name in mapped_bones.items():
            pose_bone = armature.pose.bones.get(blender_name)
            if pose_bone is None:
                continue
            deformations[vrm_name] = compute_deformation(pose_bone)
            # If this bone's Blender parent exists but is NOT in the map,
            # compute the parent's deformation so we can subtract it.
            if pose_bone.parent and pose_bone.parent.name not in mapped_bones:
                unmapped_deformations[blender_name] = compute_deformation(
                    pose_bone.parent)

        # Step 2: Derive local rotations in armature-local space (Z-up).
        # local = parent_deformation^{-1} @ bone_deformation
        # Computed in Z-up (right-handed) to keep quaternion algebra correct.
        bones = {}
        for vrm_name, deform_q in deformations.items():
            parent_vrm = vrm_parent_map.get(vrm_name)
            if parent_vrm and parent_vrm in deformations:
                parent_deform = deformations[parent_vrm]
                local_q = parent_deform.inverted() @ deform_q
            else:
                # Check for unmapped Blender parent (e.g. root/motion bone).
                blender_name = next(
                    (bn for bn, vn in mapped_bones.items() if vn == vrm_name),
                    None)
                if blender_name and blender_name in unmapped_deformations:
                    parent_deform = unmapped_deformations[blender_name]
                    local_q = parent_deform.inverted() @ deform_q
                else:
                    # True root: no parent at all.
                    local_q = deform_q

            # Step 3: Convert from armature Z-up to glTF Y-up.
            gltf_q = armature_to_gltf(local_q)

            # Normalize quaternion sign (w >= 0) to avoid slerp issues.
            if gltf_q.w < 0:
                gltf_q.negate()

            bones[vrm_name] = [round(gltf_q.x, 4), round(gltf_q.y, 4),
                               round(gltf_q.z, 4), round(gltf_q.w, 4)]

        if bones:
            frames.append({"time": time, "bones": bones})

    # Build the clip.
    clip = {
        "name": clip_name,
        "fps": fps,
        "duration": round(duration, 4),
        "loop": loop,
        "frames": frames,
    }

    # Write to file.
    if output_dir is None:
        output_dir = os.path.dirname(bpy.data.filepath) or "/tmp"
    output_path = os.path.join(output_dir, f"{clip_name}.json")

    with open(output_path, "w") as f:
        json.dump(clip, f, indent=2)

    print(f"Exported {len(frames)} frames to: {output_path}")
    return output_path


# ── Run export ──────────────────────────────────────────────────────
# Output directory resolution order:
#   1. ANICOMPANION_ANIM_OUTPUT environment variable, if set
#   2. otherwise the directory of the open .blend file (handled in export_animation)
export_animation(
    clip_name="idle",
    fps=30,
    loop=True,
    output_dir=os.environ.get("ANICOMPANION_ANIM_OUTPUT") or None,
    exclude_bones=LOWER_BODY_BONES,
)
