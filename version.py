#!/usr/bin/env python3
"""Module to manage versioning."""

__author__ = "Bogdan M. Kirilenko"


class Version:
    def __init__(self, major, minor, patch, metadata=None):
        self.major = major
        self.minor = minor
        self.patch = patch
        self.metadata = metadata
        self.version_repr = f"{major}.{minor}.{patch}"
        self.readme_repr = self.version_repr
        if self.metadata:
            self.version_repr += f" ({self.metadata})"
            self.readme_repr = f"{major}.{minor}.{patch}%20{self.metadata}"

    def update_readme(self, filename="README.md"):
        with open(filename, "r") as f:
            lines = f.readlines()

        with open(filename, "w") as f:
            for line in lines:
                if "img.shields.io/badge/version-" in line:
                    line = f'![version](https://img.shields.io/badge/version-{self.readme_repr}-blue)\n'
                f.write(line)

    def __repr__(self):
        return self.version_repr

    def to_string(self):
        return self.version_repr


__version__ = Version(2, 0, 0)

if __name__ == "__main__":
    print(f"Make Lastz Chains Version: {__version__}")
    __version__.update_readme()
    # __version__.check_changelog()
