#!/usr/bin/env python3
"""Utilities for working with 1C ParentConfigurations.bin and JSON mirror."""

from __future__ import annotations

import argparse
import json
import sys
from collections import OrderedDict, defaultdict
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree as ET


TYPE_DIR_TO_NAME = {
    "AccountingRegisters": "AccountingRegister",
    "AccumulationRegisters": "AccumulationRegister",
    "Catalogs": "Catalog",
    "ChartsOfAccounts": "ChartOfAccounts",
    "ChartsOfCharacteristicTypes": "ChartOfCharacteristicTypes",
    "CommandGroups": "CommandGroup",
    "CommonAttributes": "CommonAttribute",
    "CommonCommands": "CommonCommand",
    "CommonForms": "CommonForm",
    "CommonModules": "CommonModule",
    "CommonPictures": "CommonPicture",
    "CommonTemplates": "CommonTemplate",
    "Constants": "Constant",
    "DataProcessors": "DataProcessor",
    "DefinedTypes": "DefinedType",
    "DocumentJournals": "DocumentJournal",
    "DocumentNumerators": "DocumentNumerator",
    "Documents": "Document",
    "Enums": "Enum",
    "EventSubscriptions": "EventSubscription",
    "ExchangePlans": "ExchangePlan",
    "FilterCriteria": "FilterCriterion",
    "FunctionalOptions": "FunctionalOption",
    "FunctionalOptionsParameters": "FunctionalOptionsParameter",
    "HTTPServices": "HTTPService",
    "InformationRegisters": "InformationRegister",
    "Languages": "Language",
    "Reports": "Report",
    "Roles": "Role",
    "ScheduledJobs": "ScheduledJob",
    "SessionParameters": "SessionParameter",
    "SettingsStorages": "SettingsStorage",
    "StyleItems": "StyleItem",
    "Styles": "Style",
    "Subsystems": "Subsystem",
    "WebServices": "WebService",
    "WSReferences": "WSReference",
    "XDTOPackages": "XDTOPackage",
}

MD_NS = {"md": "http://v8.1c.ru/8.3/MDClasses"}
UNSUPPORT_EXIT_CODE = 20


def info(message: str) -> None:
    print(f"[INFO] {message}")


def warn(message: str) -> None:
    print(f"[WARN] {message}", file=sys.stderr)


def fail(message: str, exit_code: int = 1) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(exit_code)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8-sig", newline="\n")


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def dump_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def is_absolute_path(text: str) -> bool:
    return text.startswith("/") or (len(text) > 2 and text[1] == ":" and text[2] in ("/", "\\"))


def normalize_path(path_value: str) -> str:
    return path_value.replace("\\", "/")


def quote_token(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def top_level_metadata_name(metadata_name: str | None) -> str | None:
    if not metadata_name:
        return None
    parts = metadata_name.split(".")
    if len(parts) < 2:
        return metadata_name
    return f"{parts[0]}.{parts[1]}"


def tokenize_parent_config(text: str) -> list[dict]:
    stripped = text.strip()
    if not stripped.startswith("{") or not stripped.endswith("}"):
        fail("Файл ParentConfigurations.bin имеет неожиданный формат")

    tokens: list[dict] = []
    buffer: list[str] = []
    in_string = False
    token_quoted = False
    index = 1

    while index < len(stripped) - 1:
        char = stripped[index]
        if char == '"':
            if in_string and index + 1 < len(stripped) - 1 and stripped[index + 1] == '"':
                buffer.append('"')
                index += 2
                continue
            in_string = not in_string
            token_quoted = True
            index += 1
            continue
        if char == "," and not in_string:
            tokens.append({"value": "".join(buffer), "quoted": token_quoted})
            buffer = []
            token_quoted = False
        else:
            buffer.append(char)
        index += 1

    tokens.append({"value": "".join(buffer), "quoted": token_quoted})
    return tokens


def parse_parent_config(path: Path) -> dict:
    tokens = tokenize_parent_config(read_text(path))
    if len(tokens) < 4:
        fail("Файл ParentConfigurations.bin слишком короткий")

    try:
        parent_count = int(tokens[2]["value"])
    except ValueError as exc:
        fail(f"Не удалось определить число родительских конфигураций: {exc}")

    index = 4
    parents = []
    for parent_index in range(parent_count):
        header_start = index
        found_header = False
        while index + 3 < len(tokens):
            if tokens[index]["quoted"] and tokens[index + 1]["quoted"] and tokens[index + 2]["quoted"]:
                try:
                    object_count = int(tokens[index + 3]["value"])
                except ValueError:
                    index += 1
                    continue
                found_header = True
                break
            index += 1

        if not found_header:
            fail(f"Не удалось разобрать заголовок секции поддержки #{parent_index + 1}")

        header_prefix = [token["value"] for token in tokens[header_start:index]]
        version = tokens[index]["value"]
        vendor = tokens[index + 1]["value"]
        name = tokens[index + 2]["value"]
        index += 4

        objects = []
        for object_index in range(object_count):
            if index + 3 >= len(tokens):
                fail(f"Файл ParentConfigurations.bin оборван внутри секции {name}")
            objects.append(
                {
                    "index": object_index,
                    "supportState": tokens[index]["value"],
                    "vendorEditMode": tokens[index + 1]["value"],
                    "primaryGuid": tokens[index + 2]["value"],
                    "secondaryGuid": tokens[index + 3]["value"],
                }
            )
            index += 4

        parents.append(
            {
                "index": parent_index,
                "headerPrefixTokens": header_prefix,
                "version": version,
                "vendor": vendor,
                "name": name,
                "objects": objects,
            }
        )

    return {
        "fileHeaderTokens": [token["value"] for token in tokens[:4]],
        "parents": parents,
        "footerTokens": [token["value"] for token in tokens[index:]],
    }


def serialize_parent_config(data: dict) -> str:
    chunks: list[str] = []
    chunks.extend(data["fileHeaderTokens"])

    for parent in data["parents"]:
        chunks.extend(parent["headerPrefixTokens"])
        chunks.append(quote_token(parent["version"]))
        chunks.append(quote_token(parent["vendor"]))
        chunks.append(quote_token(parent["name"]))
        chunks.append(str(len(parent["objects"])))
        for obj in parent["objects"]:
            chunks.append(str(obj["supportState"]))
            chunks.append(str(obj["vendorEditMode"]))
            chunks.append(obj["primaryGuid"])
            chunks.append(obj["secondaryGuid"])

    chunks.extend(data["footerTokens"])
    return "{" + ",".join(chunks) + "}"


def load_previous_name_map(json_path: Path | None) -> dict[str, str]:
    if json_path is None or not json_path.is_file():
        return {}

    result: dict[str, str] = {}
    data = load_json(json_path)
    for parent in data.get("parents", []):
        for obj in parent.get("objects", []):
            metadata_name = obj.get("metadataName")
            if not metadata_name:
                continue
            for guid in (obj.get("primaryGuid"), obj.get("secondaryGuid")):
                if guid and guid not in result:
                    result[guid] = metadata_name
    return result


def load_configdump_name_map(configdump_path: Path | None) -> dict[str, str]:
    if configdump_path is None or not configdump_path.is_file():
        return {}

    mapping: dict[str, str] = {}
    for _event, element in ET.iterparse(configdump_path, events=("start",)):
        metadata_id = element.attrib.get("id")
        metadata_name = element.attrib.get("name")
        if metadata_id and metadata_name and metadata_id not in mapping:
            mapping[metadata_id] = metadata_name
        element.clear()
    return mapping


def export_json_data(parsed: dict, guid_to_name: dict[str, str]) -> dict:
    export = OrderedDict()
    export["formatVersion"] = 1
    export["fileHeaderTokens"] = parsed["fileHeaderTokens"]
    export["parents"] = []
    export["footerTokens"] = parsed["footerTokens"]

    unresolved = 0
    for parent in parsed["parents"]:
        parent_entry = OrderedDict()
        parent_entry["index"] = parent["index"]
        parent_entry["headerPrefixTokens"] = parent["headerPrefixTokens"]
        parent_entry["version"] = parent["version"]
        parent_entry["vendor"] = parent["vendor"]
        parent_entry["name"] = parent["name"]
        parent_entry["objects"] = []

        for obj in parent["objects"]:
            metadata_name = guid_to_name.get(obj["primaryGuid"]) or guid_to_name.get(obj["secondaryGuid"])
            if not metadata_name:
                unresolved += 1
            parent_entry["objects"].append(
                OrderedDict(
                    [
                        ("index", obj["index"]),
                        ("metadataName", metadata_name),
                        ("topLevelMetadataName", top_level_metadata_name(metadata_name)),
                        ("supportState", obj["supportState"]),
                        ("vendorEditMode", obj["vendorEditMode"]),
                        ("primaryGuid", obj["primaryGuid"]),
                        ("secondaryGuid", obj["secondaryGuid"]),
                    ]
                )
            )

        export["parents"].append(parent_entry)

    export["metadataResolution"] = OrderedDict(
        [
            ("resolvedGuids", len(guid_to_name)),
            ("unresolvedObjectRecords", unresolved),
        ]
    )
    return export


def import_json_data(path: Path) -> dict:
    data = load_json(path)
    required_root_keys = {"fileHeaderTokens", "parents", "footerTokens"}
    missing = required_root_keys - set(data.keys())
    if missing:
        fail(f"В {path} отсутствуют обязательные поля: {', '.join(sorted(missing))}")

    parsed = {
        "fileHeaderTokens": [str(item) for item in data["fileHeaderTokens"]],
        "parents": [],
        "footerTokens": [str(item) for item in data["footerTokens"]],
    }

    for parent_index, parent in enumerate(data["parents"]):
        parent_entry = {
            "index": int(parent.get("index", parent_index)),
            "headerPrefixTokens": [str(item) for item in parent.get("headerPrefixTokens", [])],
            "version": str(parent["version"]),
            "vendor": str(parent["vendor"]),
            "name": str(parent["name"]),
            "objects": [],
        }
        for object_index, obj in enumerate(parent.get("objects", [])):
            parent_entry["objects"].append(
                {
                    "index": int(obj.get("index", object_index)),
                    "supportState": str(obj["supportState"]),
                    "vendorEditMode": str(obj["vendorEditMode"]),
                    "primaryGuid": str(obj["primaryGuid"]),
                    "secondaryGuid": str(obj["secondaryGuid"]),
                }
            )
        parsed["parents"].append(parent_entry)

    return parsed


def build_guid_indexes(parsed: dict) -> tuple[dict[str, list[dict]], dict[str, set[str]]]:
    object_records_by_guid: dict[str, list[dict]] = defaultdict(list)
    top_level_to_guids: dict[str, set[str]] = defaultdict(set)

    for parent in parsed["parents"]:
        for obj in parent["objects"]:
            object_records_by_guid[obj["primaryGuid"]].append(
                {
                    "parentIndex": parent["index"],
                    "parentName": parent["name"],
                    "object": obj,
                }
            )

    return object_records_by_guid, top_level_to_guids


def build_metadata_name_indexes(
    configdump_map: dict[str, str], previous_name_map: dict[str, str]
) -> tuple[dict[str, str], dict[str, set[str]]]:
    guid_to_name = dict(previous_name_map)
    guid_to_name.update(configdump_map)

    top_level_index: dict[str, set[str]] = defaultdict(set)
    for guid, metadata_name in guid_to_name.items():
        top_name = top_level_metadata_name(metadata_name)
        if top_name:
            top_level_index[top_name].add(guid)

    return guid_to_name, top_level_index


def load_configuration_objects(config_dir: Path) -> set[str]:
    config_xml = config_dir / "Configuration.xml"
    if not config_xml.is_file():
        return set()

    result: set[str] = set()
    root = ET.parse(config_xml).getroot()
    cfg_node = root.find("md:Configuration", MD_NS)
    if cfg_node is None:
        return result
    child_objects = cfg_node.find("md:ChildObjects", MD_NS)
    if child_objects is None:
        return result

    for child in child_objects:
        if not isinstance(child.tag, str):
            continue
        tag_name = child.tag.rsplit("}", 1)[-1]
        object_name = (child.text or "").strip()
        if object_name:
            result.add(f"{tag_name}.{object_name}")
    return result


def normalize_list_entry(entry: str, config_dir: Path, config_prefix_name: str) -> str | None:
    normalized = normalize_path(entry.strip())
    if not normalized:
        return None

    if is_absolute_path(normalized):
        try:
            return normalize_path(str(Path(normalized).resolve().relative_to(config_dir.resolve())))
        except Exception:
            return None

    stripped = normalized.lstrip("./")
    if stripped.startswith(config_prefix_name + "/"):
        stripped = stripped[len(config_prefix_name) + 1 :]
    return stripped if stripped else None


def resolve_metadata_from_path(relative_path: str) -> str | None:
    normalized = normalize_path(relative_path)
    if normalized in {"Configuration.xml", "ConfigDumpInfo.xml"}:
        return None
    if normalized.startswith("Ext/"):
        return None

    parts = normalized.split("/")
    if len(parts) < 2:
        return None

    metadata_type = TYPE_DIR_TO_NAME.get(parts[0])
    if not metadata_type:
        return None

    object_name = parts[1]
    if object_name.endswith(".xml") or object_name.endswith(".bsl"):
        object_name = object_name.rsplit(".", 1)[0]
    if not object_name:
        return None

    return f"{metadata_type}.{object_name}"


def read_relative_paths(list_file: Path, config_dir: Path) -> list[str]:
    content = read_text(list_file)
    config_prefix_name = config_dir.name
    result = []
    seen = set()
    for raw_line in content.splitlines():
        normalized = normalize_list_entry(raw_line, config_dir, config_prefix_name)
        if normalized and normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def write_relative_paths(list_file: Path, relative_paths: Iterable[str]) -> None:
    unique_paths = list(OrderedDict((normalize_path(path), None) for path in relative_paths if path).keys())
    write_text(list_file, "\n".join(unique_paths) + ("\n" if unique_paths else ""))


def determine_changed_metadata(config_dir: Path, list_file: Path) -> tuple[list[str], list[str]]:
    configuration_objects = load_configuration_objects(config_dir)
    warnings: list[str] = []
    metadata_names: list[str] = []
    seen = set()

    for relative_path in read_relative_paths(list_file, config_dir):
        metadata_name = resolve_metadata_from_path(relative_path)
        if metadata_name is None:
            continue
        if configuration_objects and metadata_name not in configuration_objects:
            warnings.append(
                f"{metadata_name} не найден в Configuration.xml, путь '{relative_path}' все равно включен в preflight"
            )
        if metadata_name not in seen:
            seen.add(metadata_name)
            metadata_names.append(metadata_name)
    return metadata_names, warnings


def objects_needing_unsupport(
    parsed: dict,
    metadata_names: list[str],
    guid_to_name: dict[str, str],
    top_level_guid_index: dict[str, set[str]],
) -> tuple[list[dict], list[str]]:
    guid_records: dict[str, list[dict]] = defaultdict(list)
    for parent in parsed["parents"]:
        for obj in parent["objects"]:
            guid_records[obj["primaryGuid"]].append({"parent": parent, "object": obj})
            if obj["secondaryGuid"] != obj["primaryGuid"]:
                guid_records[obj["secondaryGuid"]].append({"parent": parent, "object": obj})

    blocked: list[dict] = []
    unresolved: list[str] = []
    blocked_by_name: set[str] = set()

    for metadata_name in metadata_names:
        guid_candidates = top_level_guid_index.get(metadata_name)
        if not guid_candidates:
            unresolved.append(metadata_name)
            continue

        for guid in sorted(guid_candidates):
            for record in guid_records.get(guid, []):
                support_state = record["object"]["supportState"]
                if support_state not in {"2", "3"} and metadata_name not in blocked_by_name:
                    blocked.append(
                        {
                            "metadataName": metadata_name,
                            "guid": guid,
                            "supportState": support_state,
                            "parentName": record["parent"]["name"],
                        }
                    )
                    blocked_by_name.add(metadata_name)
    return blocked, unresolved


def unsupport_metadata(
    parsed: dict,
    metadata_names: list[str],
    top_level_guid_index: dict[str, set[str]],
) -> tuple[int, list[str]]:
    changed_records = 0
    unresolved: list[str] = []

    guid_targets: set[str] = set()
    for metadata_name in metadata_names:
        guids = top_level_guid_index.get(metadata_name)
        if not guids:
            unresolved.append(metadata_name)
            continue
        guid_targets.update(guids)

    for parent in parsed["parents"]:
        for obj in parent["objects"]:
            if (
                obj["primaryGuid"] in guid_targets or obj["secondaryGuid"] in guid_targets
            ) and obj["supportState"] not in {"2", "3"}:
                obj["supportState"] = "2"
                changed_records += 1

    return changed_records, unresolved


def command_export_json(args: argparse.Namespace) -> None:
    bin_path = Path(args.bin).resolve()
    json_path = Path(args.json).resolve()
    configdump_path = Path(args.configdump).resolve() if args.configdump else None

    parsed = parse_parent_config(bin_path)
    previous_name_map = load_previous_name_map(json_path if json_path.exists() else None)
    configdump_map = load_configdump_name_map(configdump_path)
    guid_to_name, _top_level_index = build_metadata_name_indexes(configdump_map, previous_name_map)
    export = export_json_data(parsed, guid_to_name)
    dump_json(json_path, export)
    info(f"JSON сохранен: {json_path}")


def command_import_json(args: argparse.Namespace) -> None:
    json_path = Path(args.json).resolve()
    bin_path = Path(args.bin).resolve()
    parsed = import_json_data(json_path)
    write_text(bin_path, serialize_parent_config(parsed))
    info(f"BIN сохранен: {bin_path}")


def command_preflight_load(args: argparse.Namespace) -> None:
    config_dir = Path(args.config_dir).resolve()
    list_file = Path(args.list_file).resolve()
    bin_path = Path(args.bin).resolve()
    json_path = Path(args.json).resolve() if args.json else None
    configdump_path = Path(args.configdump).resolve() if args.configdump else None

    parsed = parse_parent_config(bin_path)
    previous_name_map = load_previous_name_map(json_path if json_path and json_path.exists() else None)
    configdump_map = load_configdump_name_map(configdump_path)
    guid_to_name, top_level_guid_index = build_metadata_name_indexes(configdump_map, previous_name_map)

    changed_metadata, warnings = determine_changed_metadata(config_dir, list_file)
    for message in warnings:
        warn(message)

    if not changed_metadata:
        info("Для preflight не найдено объектов метаданных")
        if json_path and not json_path.exists():
            export = export_json_data(parsed, guid_to_name)
            dump_json(json_path, export)
        return

    info("Проверка поддержки объектов: " + ", ".join(changed_metadata))
    blocked, unresolved = objects_needing_unsupport(parsed, changed_metadata, guid_to_name, top_level_guid_index)

    if unresolved:
        warn(
            "Не удалось сопоставить с GUID: "
            + ", ".join(unresolved)
            + ". Использованы данные ConfigDumpInfo.xml и ParentConfigurations.json."
        )

    if not blocked:
        info("Объектов, требующих снятия с поддержки, не найдено")
        return

    blocked_names = [entry["metadataName"] for entry in blocked]
    if not args.auto_unsupport:
        print("Следующие объекты нужно снять с поддержки перед загрузкой:", file=sys.stderr)
        for metadata_name in blocked_names:
            print(f"  - {metadata_name}", file=sys.stderr)
        raise SystemExit(UNSUPPORT_EXIT_CODE)

    changed_records, unresolved_on_write = unsupport_metadata(parsed, blocked_names, top_level_guid_index)
    write_text(bin_path, serialize_parent_config(parsed))
    if json_path:
        guid_to_name, _ = build_metadata_name_indexes(configdump_map, previous_name_map)
        export = export_json_data(parsed, guid_to_name)
        dump_json(json_path, export)

    relative_paths = read_relative_paths(list_file, config_dir)
    parent_bin_rel = "Ext/ParentConfigurations.bin"
    if parent_bin_rel not in relative_paths:
        relative_paths.append(parent_bin_rel)
        write_relative_paths(list_file, relative_paths)

    info(f"Снята поддержка для {len(blocked_names)} объектов, изменено записей: {changed_records}")
    if unresolved_on_write:
        warn("Часть объектов не удалось изменить: " + ", ".join(unresolved_on_write))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Work with ParentConfigurations.bin and JSON mirror",
        allow_abbrev=False,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_json_parser = subparsers.add_parser("export-json", help="Export ParentConfigurations.bin to JSON")
    export_json_parser.add_argument("--bin", required=True, help="Path to conf/Ext/ParentConfigurations.bin")
    export_json_parser.add_argument("--json", required=True, help="Path to ParentConfigurations.json")
    export_json_parser.add_argument("--configdump", default="", help="Path to ConfigDumpInfo.xml")
    export_json_parser.set_defaults(func=command_export_json)

    import_json_parser = subparsers.add_parser("import-json", help="Import ParentConfigurations.json back to BIN")
    import_json_parser.add_argument("--json", required=True, help="Path to ParentConfigurations.json")
    import_json_parser.add_argument("--bin", required=True, help="Path to conf/Ext/ParentConfigurations.bin")
    import_json_parser.set_defaults(func=command_import_json)

    preflight_parser = subparsers.add_parser("preflight-load", help="Preflight support check before partial load")
    preflight_parser.add_argument("--config-dir", required=True, help="Path to conf directory")
    preflight_parser.add_argument("--list-file", required=True, help="Path to load list file")
    preflight_parser.add_argument("--bin", required=True, help="Path to conf/Ext/ParentConfigurations.bin")
    preflight_parser.add_argument("--json", default="", help="Path to ParentConfigurations.json")
    preflight_parser.add_argument("--configdump", default="", help="Path to ConfigDumpInfo.xml")
    preflight_parser.add_argument("--auto-unsupport", action="store_true", help="Automatically set supportState=2")
    preflight_parser.set_defaults(func=command_preflight_load)

    return parser


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
