"""Generate the tree beam assets inside Unreal Editor 5.1."""
import math
from pathlib import Path

import unreal


PACKAGE = "/Game/ExhaustedResourceMarkers"
MESH_NAME = "SM_ExhaustedTreeBeam"
MATERIAL_NAME = "M_ExhaustedTreeBeam"
HEIGHT_CM = 450.0
SIDES = 16


def write_mesh_source(path):
    # Unreal's OBJ importer treats the source as Y-up meters.
    rings = ((0, 10), (24, 13), (380, 10), (HEIGHT_CM, 0.5))
    lines = []
    for height, radius in rings:
        for side in range(SIDES):
            angle = 2 * math.pi * side / SIDES
            coords = (radius * math.cos(angle), height, radius * math.sin(angle))
            lines.append("v " + " ".join(f"{value / 100:.6f}" for value in coords))
    for height, _ in rings:
        for side in range(SIDES + 1):
            lines.append(f"vt {side / SIDES:.6f} {height / HEIGHT_CM:.6f}")

    def corner(ring, side):
        vertex = ring * SIDES + (side % SIDES) + 1
        uv = ring * (SIDES + 1) + side + 1
        return f"{vertex}/{uv}"

    for ring in range(len(rings) - 1):
        for side in range(SIDES):
            a = corner(ring, side)
            b = corner(ring + 1, side)
            c = corner(ring + 1, side + 1)
            d = corner(ring, side + 1)
            lines.extend((f"f {a} {b} {c}", f"f {a} {c} {d}"))
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def import_mesh(path):
    asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
    write_mesh_source(path)
    options = unreal.FbxImportUI()
    options.set_editor_property("automated_import_should_detect_type", False)
    options.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_STATIC_MESH)
    options.set_editor_property("import_as_skeletal", False)
    options.set_editor_property("import_materials", False)
    options.set_editor_property("import_textures", False)
    mesh_options = options.get_editor_property("static_mesh_import_data")
    mesh_options.set_editor_property("combine_meshes", True)
    mesh_options.set_editor_property("auto_generate_collision", False)
    mesh_options.set_editor_property("generate_lightmap_u_vs", False)
    task = unreal.AssetImportTask()
    for key, value in {
        "filename": str(path),
        "destination_path": PACKAGE,
        "destination_name": MESH_NAME,
        "automated": True,
        "replace_existing": True,
        "replace_existing_settings": True,
        "save": False,
        "options": options,
    }.items():
        task.set_editor_property(key, value)
    asset_tools.import_asset_tasks([task])
    asset = unreal.EditorAssetLibrary.load_asset(f"{PACKAGE}/{MESH_NAME}")
    if not isinstance(asset, unreal.StaticMesh):
        raise RuntimeError("Unreal did not import a static mesh for the beam")
    bounds = asset.get_bounding_box()
    if (abs(bounds.min.z) >= 1.0 or abs(bounds.max.z - HEIGHT_CM) >= 1.0
            or bounds.max.x - bounds.min.x >= 35 or bounds.max.y - bounds.min.y >= 35):
        raise RuntimeError(f"Expected a 450 cm vertical beam from ground level, got {bounds}")
    return asset


def build_material():
    editing = unreal.MaterialEditingLibrary
    material_path = f"{PACKAGE}/{MATERIAL_NAME}"
    material = (unreal.EditorAssetLibrary.load_asset(material_path)
                if unreal.EditorAssetLibrary.does_asset_exist(material_path) else None)
    if material is None:
        material = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
            MATERIAL_NAME, PACKAGE, unreal.Material, unreal.MaterialFactoryNew())
    editing.delete_all_material_expressions(material)
    material.set_editor_property("blend_mode", unreal.BlendMode.BLEND_ADDITIVE)
    material.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    material.set_editor_property("two_sided", True)

    color = editing.create_material_expression(material, unreal.MaterialExpressionVectorParameter, -600, 0)
    color.set_editor_property("parameter_name", "BeamColor")
    color.set_editor_property("default_value", unreal.LinearColor(0.16, 2.5, 0.32, 1.0))
    fresnel = editing.create_material_expression(material, unreal.MaterialExpressionFresnel, -600, 200)
    fresnel.set_editor_property("exponent", 2.0)
    inverse = editing.create_material_expression(material, unreal.MaterialExpressionOneMinus, -350, 200)
    assert editing.connect_material_expressions(fresnel, "", inverse, "")
    assert editing.connect_material_property(color, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
    assert editing.connect_material_property(inverse, "", unreal.MaterialProperty.MP_OPACITY)
    editing.recompile_material(material)
    if not unreal.EditorAssetLibrary.save_loaded_asset(material, only_if_is_dirty=False):
        raise RuntimeError("Unreal could not save the beam material")
    return material


unreal.EditorAssetLibrary.make_directory(PACKAGE)
source = Path(unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_saved_dir())) / f"{MESH_NAME}.obj"
source.parent.mkdir(parents=True, exist_ok=True)
beam = import_mesh(source)
beam.set_material(0, build_material())
if not unreal.EditorAssetLibrary.save_loaded_asset(beam, only_if_is_dirty=False):
    raise RuntimeError("Unreal could not save the beam mesh")
# A tiny editor-only fixture gives the cooker hard references to both assets.
# The packer only ships the mesh and material.
fixture = f"{PACKAGE}/L_TreeBeamCook"
if not unreal.EditorAssetLibrary.does_asset_exist(fixture):
    levels = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
    actors = unreal.get_editor_subsystem(unreal.EditorActorSubsystem)
    if not levels.new_level(fixture):
        raise RuntimeError("Could not create the beam cook fixture")
    actor = actors.spawn_actor_from_object(beam, unreal.Vector())
    if not actor or not levels.save_current_level():
        raise RuntimeError("Could not save the beam cook fixture")
unreal.log("Exhausted Resource Markers beam assets saved")
