"""Small archive helpers. Extract regular files only, within the destination."""
from pathlib import Path, PurePosixPath
import shutil
import tarfile


def unpack(path, destination):
    destination = Path(destination).resolve()
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe archive path: ' + member.name)
            target = destination.joinpath(*relative.parts).resolve()
            if not target.is_relative_to(destination):
                raise ValueError('Archive path escaped destination.')
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open('wb') as out:
                    shutil.copyfileobj(source, out)
            else:
                raise ValueError('Non-regular archive member: ' + member.name)


def pack(target, root, paths):
    target, root = Path(target), Path(root).resolve()
    temp = target.with_suffix(target.suffix + '.partial')
    with tarfile.open(temp, 'w:gz', compresslevel=3) as archive:
        seen = set()
        for relative in paths:
            path = root / relative
            if not path.exists():
                continue
            candidates = path.rglob('*') if path.is_dir() else [path]
            for candidate in sorted(candidates):
                resolved = candidate.resolve()
                if candidate.is_symlink() or not resolved.is_relative_to(root):
                    raise ValueError('Unsafe output path.')
                if candidate.is_file():
                    name = candidate.relative_to(root).as_posix()
                    if name not in seen:
                        archive.add(candidate, arcname=name, recursive=False)
                        seen.add(name)
    temp.replace(target)
