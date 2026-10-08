import Domain
import os

/// This module's logger category. Every module logs under its own.
nonisolated let logCategory = LogCategory.serverAPI

/// This module's logger.
nonisolated let log = Diagnostics.logger(logCategory)
