# Packaging Aether for package managers

Recipes for **easy install** via package managers. Primary binary name: **`aether-grok`**.

Short name `aether` is **not** installed by packages (conflicts with Arch’s [aether](https://github.com/bjarneo/aether) desktop theme app).

## Shared install target

Package builds should use:

```bash
make bootstrap-odin   # if Odin is not already on PATH
make build
make DESTDIR=… PREFIX=/usr install-prefix
```

`scripts/install-prefix.sh` installs:

| Path | Notes |
|------|--------|
| `$PREFIX/bin/aether-grok` | Real binary |
| `$PREFIX/bin/aether-grok-odin` | Symlink |
| `$PREFIX/bin/grok-odin` | Symlink |
| bash completion | `aether-grok` |

Developer machine install remains `make install` → `~/.local/bin` (symlinks).

## Arch Linux (AUR)

### Local package (no AUR publish yet)

```bash
cd packaging/aur/aether-grok-git
makepkg -si
# or: makepkg -s && sudo pacman -U aether-grok-git-*.pkg.tar.zst
```

### After publishing to AUR

```bash
yay -S aether-grok-git
# or
paru -S aether-grok-git
```

**Depends:** `curl`, `mbedtls`, `ripgrep`  
**Build:** `git`, `clang`, `llvm`, `make` + Odin via `make bootstrap-odin`

Publish steps (maintainer):

1. Create AUR package `aether-grok-git` (SSH: `aur@aur.archlinux.org:aether-grok-git.git`)
2. Copy `PKGBUILD` + generate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`
3. Commit and push to AUR

## Homebrew (Linux + macOS)

### Local formula (from this tree)

```bash
brew install --build-from-source ./packaging/homebrew/aether-grok.rb
```

### Future tap (recommended for users)

```bash
# After publishing packaging/homebrew/aether-grok.rb to a homebrew-aether repo:
brew tap BRONZowl/aether
brew install aether-grok
```

**Depends:** `curl`, `mbedtls`, `ripgrep`  
**Build:** `llvm`, `make` + Odin bootstrap

## Runtime requirements (all packages)

| Package | Why |
|---------|-----|
| libcurl | HTTP / API |
| mbedTLS | Linked by Odin curl vendor |
| ripgrep (`rg`) | `grep` / `glob` tools |

Optional: `pdftotext`, `unzip`, ImageMagick for media helpers.

## Auth after install

```bash
export XAI_API_KEY=...
aether-grok --version
aether-grok -p "say hi in three words"
aether-grok          # TUI on a TTY
```

## Not in this tree (later)

- Stable non-git AUR package (`aether-grok`) pinned to release tarballs  
- Prebuilt binary packages (no Odin bootstrap)  
- deb/rpm/Nix — same `install-prefix` target applies  
