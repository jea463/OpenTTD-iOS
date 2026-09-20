/* This file is part of OpenTTD. Licensed under GPL version 2; see COPYING.md. */
#include "../../stdafx.h"
#include "../../debug.h"
#include "../../fios.h"
#include "../../fileio_func.h"
#include "../../window_func.h"
#include "../../openttd.h"
#include "../../progress.h"
#include "../../saveload/saveload.h"
#include "../../settings_func.h"
#include "ios_persistence.h"
#include <fcntl.h>
#include <fstream>
#include <thread>
#include <unistd.h>

namespace {
std::filesystem::path resume_directory;
std::thread::id engine_owner;
bool resume_in_flight = false;

bool OnEngineThread()
{
    if (std::this_thread::get_id() == engine_owner) return true;
    Debug(misc, 0, "iOS persistence rejected call outside engine owner thread");
    return false;
}

bool CheckedSave(const std::filesystem::path &path)
{
    std::error_code error;
    if (!std::filesystem::is_regular_file(path, error)) return false;
    _load_check_data.Clear();
    auto result = SaveOrLoad(path.string(), SLO_CHECK, DFT_GAME_FILE, NO_DIRECTORY, false);
    bool valid = result == SL_OK && _load_check_data.checkable && !_load_check_data.HasErrors() &&
        _load_check_data.map_size_x >= 64 && _load_check_data.map_size_y >= 64;
    _load_check_data.Clear();
    if (!valid) Debug(misc, 0, "iOS resume validation rejected {}", path.string());
    return valid;
}

bool SyncFile(const std::filesystem::path &path)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    bool ok = fsync(fd) == 0;
    close(fd);
    return ok;
}

void SyncDirectory()
{
    int fd = open(resume_directory.c_str(), O_RDONLY);
    if (fd < 0) return;
    fsync(fd);
    close(fd);
}
}

std::optional<std::string> IOSPrepareResume(const char *documents_path, const char *executable_path)
{
    engine_owner = std::this_thread::get_id();
    resume_directory = std::filesystem::path(documents_path) / "save";
    try {
        std::filesystem::create_directories(resume_directory);
        /* Even absolute NO_DIRECTORY reads require initialized upstream search paths. */
        extern std::string _config_file;
        _config_file = (std::filesystem::path(documents_path) / "openttd.cfg").string();
        DeterminePaths(executable_path, false);
        std::vector<std::string> interrupted;
        std::ifstream previous_attempt(resume_directory / "resume-attempt.txt");
        for (std::string line; std::getline(previous_attempt, line);) interrupted.push_back(std::move(line));
        for (const char *name : {"resume.sav", "resume-previous.sav"}) {
            auto candidate = resume_directory / name;
            if (std::ranges::find(interrupted, name) != interrupted.end()) {
                Debug(misc, 0, "iOS resume skipping interrupted load of {}; manual save remains available", name);
                continue;
            }
            if (!CheckedSave(candidate)) continue;
            auto marker_pending = resume_directory / "resume-attempt-pending.txt";
            {
                std::ofstream marker(marker_pending, std::ios::trunc);
                for (const auto &failed : interrupted) marker << failed << '\n';
                marker << name << '\n';
                marker.close();
                if (!marker) return std::nullopt;
            }
            if (!SyncFile(marker_pending)) return std::nullopt;
            std::filesystem::rename(marker_pending, resume_directory / "resume-attempt.txt");
            SyncDirectory();
            resume_in_flight = true;
            Debug(misc, 0, "iOS resume selected {}", candidate.string());
            return candidate.string();
        }
    } catch (const std::exception &error) {
        Debug(misc, 0, "iOS resume selection failed; opening menu: {}", error.what());
    }
    Debug(misc, 0, "iOS resume has no usable candidate; opening menu");
    return std::nullopt;
}

void IOSResumeLoadCompleted()
{
    if (!resume_in_flight || !OnEngineThread()) return;
    if (_game_mode != GM_NORMAL || _switch_mode != SM_NONE || HasModalProgress()) return;
    std::error_code error;
    std::filesystem::remove(resume_directory / "resume-attempt.txt", error);
    if (error) {
        Debug(misc, 0, "iOS resume could not clear load marker: {}", error.message());
        return;
    }
    SyncDirectory();
    resume_in_flight = false;
    Debug(misc, 0, "iOS resume full load confirmed by normal game tick");
}

bool IOSSaveResume()
{
    if (!OnEngineThread() || HasModalProgress()) return false;
    try {
        SaveToConfig();
        if (_game_mode != GM_NORMAL || _switch_mode != SM_NONE || FindWindowByClass(WC_SAVELOAD) != nullptr) {
            Debug(misc, 1, "iOS background saved config only; no stable normal game");
            return false;
        }
        auto pending = resume_directory / "resume-pending.sav";
        auto current = resume_directory / "resume.sav";
        auto previous = resume_directory / "resume-previous.sav";
        auto backup_pending = resume_directory / "resume-backup-pending.sav";
        if (SaveOrLoad(pending.string(), SLO_SAVE, DFT_GAME_FILE, NO_DIRECTORY, false) != SL_OK ||
                !CheckedSave(pending) || !SyncFile(pending)) {
            Debug(misc, 0, "iOS resume save/verification failed; prior saves retained");
            return false;
        }
        /* Do not replace a good backup with a corrupt current save. */
        if (CheckedSave(current)) {
            std::filesystem::copy_file(current, backup_pending, std::filesystem::copy_options::overwrite_existing);
            if (!SyncFile(backup_pending)) return false;
            std::filesystem::rename(backup_pending, previous);
            SyncDirectory();
        }
        /* Same-directory rename replaces current atomically; a failure leaves it intact. */
        std::filesystem::rename(pending, current);
        /* This newly verified snapshot supersedes any earlier failed load attempt. */
        std::error_code marker_error;
        std::filesystem::remove(resume_directory / "resume-attempt.txt", marker_error);
        resume_in_flight = false;
        SyncDirectory();
        Debug(misc, 0, "iOS resume saved and verified {}", current.string());
        return true;
    } catch (const std::exception &error) {
        Debug(misc, 0, "iOS resume save failed; prior saves retained: {}", error.what());
        return false;
    }
}
