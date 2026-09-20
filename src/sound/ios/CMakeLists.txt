# Keep native Objective-C++ out of the C++ engine's precompiled-header domain.
target_sources(openttd PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/ios_sound.mm)
