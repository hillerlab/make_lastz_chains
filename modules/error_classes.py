"""Classes that define specific pipeline exceptions."""


class PipelineSubprocessError(Exception):
    pass


class NextflowProcessError(Exception):
    pass


class PipelineFileNotFound(Exception):
    pass
