"""Step status enum."""
from enum import Enum


class StepStatus(Enum):
    NOT_STARTED = "not_started"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    SKIPPED = "skipped"

    @classmethod
    def from_string(cls, value):
        return cls(value)
