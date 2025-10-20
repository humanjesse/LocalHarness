# Deployment and Release Guide

This guide covers the standard procedures for deploying ZodoLlama updates, creating releases, and managing the GitHub repository.

## Table of Contents
1. [Daily Development Workflow](#daily-development-workflow)
2. [Commit Message Guidelines](#commit-message-guidelines)
3. [Creating Releases](#creating-releases)
4. [Semantic Versioning](#semantic-versioning)
5. [GitHub Release Checklist](#github-release-checklist)
6. [Branch Strategy](#branch-strategy)
7. [Common Scenarios](#common-scenarios)

---

## Daily Development Workflow

### 1. Making Changes
```bash
# Make your code changes
# Test locally
zig build
./zig-out/bin/zodollama

# Check what changed
git status
git diff
```

### 2. Staging and Committing
```bash
# Stage specific files
git add main.zig ui.zig

# Or stage all changes
git add .

# Commit with a descriptive message
git commit -m "Fix scrolling issue in chat history"
```

### 3. Pushing to GitHub
```bash
# Push to main branch
git push origin main

# First time pushing a new branch
git push -u origin branch-name
```

---

## Commit Message Guidelines

### Format
```
<type>: <short description>

[optional longer description]

[optional footer]
```

### Types
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, no logic change)
- `refactor:` - Code refactoring (no functionality change)
- `perf:` - Performance improvements
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks (dependencies, build config)

### Examples

**Good commits:**
```bash
git commit -m "feat: add dark mode support"
git commit -m "fix: resolve crash when terminal resizes during streaming"
git commit -m "docs: update README with macOS installation instructions"
git commit -m "refactor: simplify markdown table rendering logic"
```

**Bad commits (avoid these):**
```bash
git commit -m "fixed stuff"
git commit -m "wip"
git commit -m "more changes"
git commit -m "asdf"
```

### Multi-line Commits (for bigger changes)
```bash
git commit -m "feat: add emoji skin tone support

- Implement ZWJ sequence detection
- Add width calculation for modifiers
- Update getCharWidth function with new ranges
- Add tests for family emoji rendering"
```

---

## Semantic Versioning

ZodoLlama follows [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`

### Version Format: `vX.Y.Z`
- **MAJOR (X)**: Breaking changes (API changes, incompatible updates)
- **MINOR (Y)**: New features (backwards-compatible)
- **PATCH (Z)**: Bug fixes (backwards-compatible)

### Examples
- `v0.1.0` → `v0.1.1`: Fixed a bug (PATCH)
- `v0.1.1` → `v0.2.0`: Added new feature like table support (MINOR)
- `v0.2.0` → `v1.0.0`: Major rewrite or breaking config change (MAJOR)

### Pre-1.0 Versions
- Before `v1.0.0`, the project is considered in development
- Breaking changes can happen in minor versions
- Example: `v0.1.0` → `v0.2.0` might have breaking changes

### When to Increment

**PATCH (0.1.0 → 0.1.1):**
- Fixed a crash
- Fixed rendering issue
- Performance improvements
- Small refactors

**MINOR (0.1.0 → 0.2.0):**
- New markdown feature (e.g., code highlighting)
- New configuration option
- New keyboard shortcut
- Non-breaking improvements

**MAJOR (0.9.0 → 1.0.0):**
- Config file format changes
- Removed features
- Changed default behavior significantly
- Command-line argument changes

---

## Creating Releases

### Step 1: Prepare the Release

1. **Ensure all changes are committed:**
   ```bash
   git status
   # Should show: "nothing to commit, working tree clean"
   ```

2. **Update version in relevant files** (if applicable):
   - README.md (if version mentioned)
   - Any version constants in code

3. **Test the build:**
   ```bash
   zig build -Doptimize=ReleaseSafe
   ./zig-out/bin/zodollama
   # Test major features to ensure they work
   ```

4. **Review recent changes:**
   ```bash
   git log --oneline
   # Review commits since last release
   ```

### Step 2: Create and Push Tag

1. **Create annotated tag:**
   ```bash
   # Format: git tag -a vX.Y.Z -m "Release vX.Y.Z"
   git tag -a v0.1.0 -m "Release v0.1.0 - Initial public release"
   ```

2. **Push the tag:**
   ```bash
   git push origin v0.1.0
   ```

3. **GitHub Actions will automatically:**
   - Build the Linux x86_64 binary
   - Generate checksums
   - Create a GitHub release
   - Attach the binary and checksums

### Step 3: Verify the Release

1. Go to: `https://github.com/humanjesse/zodollama/releases`
2. Check that the release was created
3. Verify the binary is attached
4. Download and test the binary

### Step 4: Edit Release Notes (Optional)

GitHub will auto-generate release notes, but you can enhance them:

1. Go to the release page
2. Click "Edit"
3. Add highlights:
   ```markdown
   ## Highlights
   - 🎉 New feature: Table rendering support
   - 🐛 Fixed crash during window resize
   - ⚡ Improved markdown parsing performance by 30%

   ## Breaking Changes
   None

   ## Full Changelog
   [Auto-generated section follows...]
   ```

---

## GitHub Release Checklist

Use this checklist when creating a release:

- [ ] All changes committed and pushed to `main`
- [ ] Build succeeds locally: `zig build -Doptimize=ReleaseSafe`
- [ ] Tested main features work correctly
- [ ] Version number decided (MAJOR.MINOR.PATCH)
- [ ] Created annotated tag: `git tag -a vX.Y.Z -m "..."`
- [ ] Pushed tag: `git push origin vX.Y.Z`
- [ ] Verified GitHub Actions workflow succeeded
- [ ] Downloaded and tested release binary
- [ ] Updated release notes with highlights (optional)
- [ ] Announced release (if applicable)

---

## Branch Strategy

### Simple Solo Developer Strategy

**For now (solo development):**
- Work directly on `main` branch
- Use good commit messages
- Tag releases when ready

**Advantages:**
- Simple and fast
- No overhead
- Works great for solo projects

### Advanced Strategy (Optional - for later)

When the project grows or you have contributors:

**Branches:**
- `main` - Stable, always deployable
- `develop` - Active development
- `feature/feature-name` - New features
- `fix/bug-description` - Bug fixes

**Workflow:**
```bash
# Create feature branch
git checkout -b feature/syntax-highlighting

# Make changes and commit
git add .
git commit -m "feat: add syntax highlighting for code blocks"

# Push feature branch
git push -u origin feature/syntax-highlighting

# When ready, merge to main via GitHub Pull Request
# (or locally: git checkout main && git merge feature/syntax-highlighting)
```

---

## Common Scenarios

### Scenario 1: Bug Fix Release

```bash
# 1. Fix the bug
vim ui.zig
zig build && ./zig-out/bin/zodollama  # Test

# 2. Commit
git add ui.zig
git commit -m "fix: prevent crash when terminal width is very small"

# 3. Push
git push origin main

# 4. Create patch release
git tag -a v0.1.1 -m "Release v0.1.1 - Fix crash on small terminals"
git push origin v0.1.1
```

### Scenario 2: New Feature Release

```bash
# 1. Develop feature (might take multiple commits)
git commit -m "feat: add syntax highlighting for code blocks"
git commit -m "feat: support multiple highlighting themes"
git commit -m "docs: update README with syntax highlighting info"

# 2. Push all commits
git push origin main

# 3. Create minor release
git tag -a v0.2.0 -m "Release v0.2.0 - Add syntax highlighting"
git push origin v0.2.0
```

### Scenario 3: Mistake in Last Commit (Not Pushed Yet)

```bash
# Oops, forgot to add a file
git add forgotten_file.zig
git commit --amend --no-edit

# Or fix the commit message
git commit --amend -m "fix: correct message"

# Note: Only do this if you haven't pushed yet!
```

### Scenario 4: Need to Fix a Released Version

```bash
# If you found a critical bug in v0.1.0 after release

# 1. Fix the bug
git commit -m "fix: critical security issue in input handling"

# 2. Create new patch release
git tag -a v0.1.1 -m "Release v0.1.1 - Security fix"
git push origin main
git push origin v0.1.1

# The old release stays, new release is now available
```

### Scenario 5: Want to Delete a Bad Tag

```bash
# Delete local tag
git tag -d v0.1.0

# Delete remote tag
git push origin :refs/tags/v0.1.0

# Or delete remote tag (alternative syntax)
git push origin --delete v0.1.0

# Note: Only do this if the release is very new and no one has downloaded it
# Generally, it's better to create a new patch version instead
```

### Scenario 6: See What Changed Since Last Release

```bash
# List tags
git tag

# Show changes since last tag
git log v0.1.0..HEAD --oneline

# Detailed view
git log v0.1.0..HEAD

# See diff
git diff v0.1.0..HEAD
```

---

## Quick Reference

### Common Commands

```bash
# Check status
git status

# See what changed
git diff

# Stage changes
git add <file>
git add .

# Commit
git commit -m "message"

# Push
git push origin main

# Create tag
git tag -a v0.1.0 -m "Release v0.1.0"

# Push tag
git push origin v0.1.0

# List tags
git tag -l

# View commit history
git log --oneline
```

### Emergency Undo Commands

```bash
# Undo last commit (keep changes)
git reset HEAD~1

# Undo last commit (discard changes) - DANGEROUS!
git reset --hard HEAD~1

# Discard changes to a file
git checkout -- filename.zig

# Unstage a file
git reset HEAD filename.zig
```

---

## Best Practices

### DO:
✅ Commit often with clear messages
✅ Test before pushing
✅ Use semantic versioning
✅ Write meaningful commit messages
✅ Tag releases properly
✅ Keep commits focused (one logical change per commit)

### DON'T:
❌ Commit broken code to `main`
❌ Use `git commit -m "wip"` or "fixed stuff"
❌ Push without testing
❌ Delete tags after people have downloaded them
❌ Commit sensitive information (API keys, passwords)
❌ Have giant commits with many unrelated changes

---

## Getting Help

- **Git Documentation:** https://git-scm.com/doc
- **GitHub Docs:** https://docs.github.com
- **Semantic Versioning:** https://semver.org
- **Conventional Commits:** https://www.conventionalcommits.org

---

## Your First Release Walkthrough

Let's walk through creating your first public release:

```bash
# 1. Make sure everything is committed
git status
# Output: nothing to commit, working tree clean ✓

# 2. Test the build
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zodollama
# Manual testing: send a message, check markdown rendering, test scrolling ✓

# 3. Create the first release tag
git tag -a v0.1.0 -m "Release v0.1.0 - Initial public release

Features:
- Real-time AI chat with Ollama
- Beautiful markdown rendering
- Non-blocking streaming
- Mouse support and scrolling
- Configurable colors and models
- Table rendering
- Emoji support"

# 4. Push to GitHub
git push origin main           # Push all commits
git push origin v0.1.0         # Push the tag

# 5. Wait a few minutes for GitHub Actions to build

# 6. Go to https://github.com/humanjesse/zodollama/releases
# You should see v0.1.0 with the binary attached!

# 7. Download the binary and test it
wget https://github.com/humanjesse/zodollama/releases/download/v0.1.0/zodollama-linux-x86_64
chmod +x zodollama-linux-x86_64
./zodollama-linux-x86_64

# 8. Done! 🎉 Your project is now publicly released!
```

---

Remember: **It's okay to make mistakes!** Git is very forgiving, and you can almost always undo things. The most important thing is to learn and improve with each release.

Happy deploying! 🚀
