"""Package source-only teammate handoffs; never include local data or credentials."""
import argparse
import shutil
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
IGNORE = {".git", ".venv", "__pycache__", ".pytest_cache", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store", ".env"}


def source_file(path):
    generated_ios = path.parts[:3] == ("clients", "ios", "Configuration")
    retired_preview = str(path) in {"docs/prototype-preview.jpg", "docs/ios-preview.jpg", "docs/ios-capture.jpg", "docs/ios-discovery.jpg"}
    environment_file = path.name.startswith(".env") and path.name != ".env.example"
    return not generated_ios and not retired_preview and not environment_file and not any(part in IGNORE or part.endswith(".xcodeproj") or part.endswith(".xcworkspace") for part in path.parts) and path.suffix not in {".db", ".pyc"} and not path.name.endswith((".db-wal", ".db-shm"))


def archive(path, files, prefix=""):
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as bundle:
        for source, relative in sorted(files):
            bundle.write(source, prefix + str(relative))
    print(path.relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="Include the backend and both client frameworks")
    parser.add_argument("--sidepanel", action="store_true", help="Package only the combined side-panel extension")
    parser.add_argument("--legacy-popup", action="store_true", help="Package the older popup instead of the combined app")
    args = parser.parse_args()
    DIST.mkdir(exist_ok=True)
    for directory in ["extension/lib", "frontend/lib", "experiments/chrome-sidepanel/lib"]:
        bundled = ROOT / directory / "client.js"
        bundled.parent.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "clients/javascript/client.js", bundled)
    unpacked = DIST / "chrome-extension"
    if unpacked.exists():
        shutil.rmtree(unpacked)
    source = ROOT / ("extension" if args.legacy_popup else "experiments/chrome-sidepanel")
    shutil.copytree(source, unpacked, ignore=shutil.ignore_patterns("tests", "package.json", ".DS_Store"))
    archive(DIST / "mymah-finds-chrome-extension.zip", [(p, p.relative_to(unpacked)) for p in unpacked.rglob("*") if p.is_file()])
    if args.all:
        entries = ["backend", "clients", "contracts", "docs", "extension", "experiments/chrome-sidepanel", "frontend", "scripts", ".github", "app.py", "vercel.json", ".vercelignore", "README.md", "Makefile", "pyproject.toml", "requirements.lock", "alembic.ini", "compose.yaml", ".env.example", ".gitignore"]
        files = []
        for entry in entries:
            base = ROOT / entry
            for path in ([base] if base.is_file() else base.rglob("*")):
                if path.is_file() and source_file(path.relative_to(ROOT)):
                    files.append((path, path.relative_to(ROOT)))
        archive(DIST / "mymah-finds-framework.zip", files, "mymah-finds/")


if __name__ == "__main__":
    main()
