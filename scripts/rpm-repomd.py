#!/usr/bin/env python3
# Copyright 2026-present raml-dev
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
from pathlib import Path

import createrepo_c as cr


RECORD_TYPES = ("primary", "filelists", "other")


def load_repodata_hrefs(repomd_path: Path) -> list[str]:
    repomd = cr.Repomd(str(repomd_path))
    hrefs: list[str] = []
    for record in repomd.records:
        if record.type in RECORD_TYPES:
            hrefs.append(record.location_href)
    return hrefs


def parse_packages(path: Path | None, parser) -> list[object]:
    if path is None or not path.exists():
        return []
    packages: list[object] = []
    parser(str(path), pkgcb=lambda pkg: packages.append(pkg))
    return packages


def filter_existing_packages(packages: list[object], location_href: str) -> list[object]:
    return [pkg for pkg in packages if getattr(pkg, "location_href", None) != location_href]


def write_xml_file(xml_class, output_path: Path, packages: list[object], new_package: object, stat: object) -> Path:
    writer = xml_class(str(output_path), cr.GZ, stat)
    writer.set_num_of_pkgs(len(packages) + 1)
    for package in packages:
        writer.add_pkg(package)
    writer.add_pkg(new_package)
    writer.close()
    return output_path


def update_repodata(repo_dir: Path, repomd_path: Path | None, package_path: Path, location_href: str, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    existing_paths: dict[str, Path] = {}
    if repomd_path is not None and repomd_path.exists():
        for href in load_repodata_hrefs(repomd_path):
            metadata_path = repo_dir / href
            name = Path(href).name
            if name.endswith("-primary.xml.gz"):
                existing_paths["primary"] = metadata_path
            elif name.endswith("-filelists.xml.gz"):
                existing_paths["filelists"] = metadata_path
            elif name.endswith("-other.xml.gz"):
                existing_paths["other"] = metadata_path

    primary_packages = filter_existing_packages(
        parse_packages(existing_paths.get("primary"), cr.xml_parse_primary),
        location_href,
    )
    filelists_packages = filter_existing_packages(
        parse_packages(existing_paths.get("filelists"), cr.xml_parse_filelists),
        location_href,
    )
    other_packages = filter_existing_packages(
        parse_packages(existing_paths.get("other"), cr.xml_parse_other),
        location_href,
    )

    new_package = cr.package_from_rpm(
        str(package_path),
        checksum_type=cr.SHA256, # pyright: ignore[reportAttributeAccessIssue]
        location_href=location_href,
        changelog_limit=10,
    )

    primary_stat = cr.ContentStat(cr.SHA256) # pyright: ignore[reportAttributeAccessIssue]
    filelists_stat = cr.ContentStat(cr.SHA256) # pyright: ignore[reportAttributeAccessIssue]
    other_stat = cr.ContentStat(cr.SHA256) # pyright: ignore[reportAttributeAccessIssue]

    primary_path = write_xml_file(
        cr.PrimaryXmlFile,
        output_dir / "primary.xml.gz",
        primary_packages,
        new_package,
        primary_stat,
    )
    filelists_path = write_xml_file(
        cr.FilelistsXmlFile,
        output_dir / "filelists.xml.gz",
        filelists_packages,
        new_package,
        filelists_stat,
    )
    other_path = write_xml_file(
        cr.OtherXmlFile,
        output_dir / "other.xml.gz",
        other_packages,
        new_package,
        other_stat,
    )

    repomd = cr.Repomd()
    for record_type, path, stat in (
        ("primary", primary_path, primary_stat),
        ("filelists", filelists_path, filelists_stat),
        ("other", other_path, other_stat),
    ):
        record = cr.RepomdRecord(record_type, str(path))
        record.load_contentstat(stat)
        record.fill(cr.SHA256) # pyright: ignore[reportAttributeAccessIssue]
        record.rename_file()
        repomd.set_record(record)

    repomd.sort_records()
    (output_dir / "repomd.xml").write_text(repomd.xml_dump(), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list-hrefs")
    list_parser.add_argument("--repomd", required=True)

    update_parser = subparsers.add_parser("update")
    update_parser.add_argument("--repo-dir", required=True)
    update_parser.add_argument("--repomd")
    update_parser.add_argument("--package-path", required=True)
    update_parser.add_argument("--location-href", required=True)
    update_parser.add_argument("--output-dir", required=True)

    args = parser.parse_args()

    if args.command == "list-hrefs":
        for href in load_repodata_hrefs(Path(args.repomd)):
            print(href)
        return

    update_repodata(
        repo_dir=Path(args.repo_dir),
        repomd_path=Path(args.repomd) if args.repomd else None,
        package_path=Path(args.package_path),
        location_href=args.location_href,
        output_dir=Path(args.output_dir),
    )


if __name__ == "__main__":
    main()
