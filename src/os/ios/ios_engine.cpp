/* This file is part of OpenTTD. Licensed under GPL version 2; see COPYING.md. */
#include "../../stdafx.h"
#include "../../openttd.h"
#include "../../crashlog.h"
#include "../../core/random_func.hpp"
#include "../../survey.h"
#include "../../debug.h"
#include "ios_bridge.h"
#include "ios_persistence.h"
#include <ctime>
#include <thread>

#include <csignal>
#include <sys/utsname.h>
#include <unistd.h>

/* iOS keeps native crash reports; installing desktop signal handlers is inappropriate. */
void CrashLog::InitialiseCrashLog() {}
void CrashLog::InitThread() {}
std::optional<std::string> GetCurrentLocale(const char *) { return "en_GB"; }
void OSOpenBrowser(const std::string &url) { Debug(misc, 0, "External browser unavailable in initial iOS adapter: {}", url); }
void SurveyOS(nlohmann::json &json)
{
    struct utsname info{};
    uname(&info);
    json["os"] = "iOS";
    json["release"] = info.release;
    json["machine"] = info.machine;
    json["hardware_concurrency"] = std::thread::hardware_concurrency();
}
void IOSRunEngine(const char *resourcePath, const char *documentsPath)
{
    SetRandomSeed(std::time(nullptr));
    signal(SIGPIPE, SIG_IGN);
    std::filesystem::create_directories(documentsPath);
    chdir(documentsPath);
    std::string executable = std::string(resourcePath) + "/openttd";
    std::string config = std::string(documentsPath) + "/openttd.cfg";
    std::vector<std::string_view> args{executable, "-c", config, "-v", "ios", "-b", "32bpp-anim", "-s", "ios", "-m", "null", "-d", "misc=3,driver=3"};
    auto resume = IOSPrepareResume(documentsPath, executable.c_str());
    if (resume.has_value()) { args.emplace_back("-g"); args.emplace_back(*resume); }
    fmt::print(stderr, "iOS engine starting: bundle={}, documents={}\n", resourcePath, documentsPath);
    int result = openttd_main(args);
    fmt::print(stderr, "iOS engine returned {}\n", result);
}
