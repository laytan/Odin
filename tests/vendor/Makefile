ODIN=../../odin
COMMON=-vet -strict-style
MACOSX_MIN=11

all: glfw_test \
	raylib_test

glfw_test:
	$(ODIN) run glfw $(COMMON) -out:vendor_glfw
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/glfw/lib/darwin/libglfw3.a $(MACOSX_MIN)

raylib_test:
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos-arm64/libraygui.a $(MACOSX_MIN)
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos-arm64/libraylib.a $(MACOSX_MIN)
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos-arm64/libraylib.5.0.0.dylib $(MACOSX_MIN)

	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos/libraygui.a $(MACOSX_MIN)
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos/libraylib.a $(MACOSX_MIN)
	$(PYTHON) ./check_macosx_min_version.py ../../vendor/raylib/macos/libraylib.5.0.0.dylib $(MACOSX_MIN)
