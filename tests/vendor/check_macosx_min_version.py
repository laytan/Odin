#!/usr/bin/env python3

import subprocess
import sys

def main(path, version):
	if sys.platform != "darwin":
		print("skipping test - not on darwin")
		return 0

	try:
		output = subprocess.check_output(["otool", "-l", path])
		if f"minos {version}" in output.decode("utf-8"):
			return 0
		else:
			print(f"Expected {path} to be built with -mmacosx-version-min={version}")
			return 1

	except subprocess.CalledProcessError as e:
		print(f"Error executing `otool` command: {e}")
		return 1

if __name__ == "__main__":
	sys.exit(main(sys.argv[1], sys.argv[2]))
