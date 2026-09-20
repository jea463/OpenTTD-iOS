enable_language(OBJCXX)
set(IOS_BUNDLE_IDENTIFIER "org.openttd.ios.dev" CACHE STRING "iOS application bundle identifier")
target_compile_options(openttd PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
set_target_properties(openttd PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/ios/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${IOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${IOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    MACOSX_BUNDLE_BUNDLE_NAME "OpenTTD"
    MACOSX_BUNDLE_BUNDLE_VERSION "1"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "15.3"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)
target_link_libraries(openttd "-framework AudioToolbox" "-framework AVFAudio" "-framework CoreGraphics" "-framework UIKit" "-framework Foundation" "-framework Metal" "-framework MetalKit" "-framework QuartzCore")
get_filename_component(IOS_DEPENDENCY_PREFIX "${LIBLZMA_INCLUDE_DIR}" DIRECTORY)
add_custom_command(TARGET openttd POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${IOS_DEPENDENCY_PREFIX}/share/licenses" "$<TARGET_BUNDLE_DIR:openttd>/licenses"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_BINARY_DIR}/lang" "$<TARGET_BUNDLE_DIR:openttd>/lang"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_BINARY_DIR}/baseset" "$<TARGET_BUNDLE_DIR:openttd>/baseset"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/build/ios-assets/baseset" "$<TARGET_BUNDLE_DIR:openttd>/baseset"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/bin/ai" "$<TARGET_BUNDLE_DIR:openttd>/ai"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/bin/game" "$<TARGET_BUNDLE_DIR:openttd>/game"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_SOURCE_DIR}/COPYING.md" "${CMAKE_SOURCE_DIR}/README.md" "${CMAKE_SOURCE_DIR}/CREDITS.md" "$<TARGET_BUNDLE_DIR:openttd>"
)
