"""Classes that define specific pipeline exceptions."""


class PipelineSubprocessError(Exception):
    pass


class NextflowProcessError(Exception):
    pass


class PipelineFileNotFoundError(Exception):
    pass


class ExecutableNotFoundError(Exception):
    pass
