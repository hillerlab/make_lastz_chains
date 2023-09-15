"""Logging module."""
import logging

LOGGER_ID = "make_chains"


def setup_logger(log_file, write_to_console=True):
    # Set up logging
    logger = logging.getLogger(LOGGER_ID)
    logger.setLevel(logging.INFO)

    if write_to_console:
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
        logger.addHandler(console_handler)

    if log_file:
        file_handler = logging.FileHandler(log_file)
        file_handler.setLevel(logging.INFO)
        logger.addHandler(file_handler)


def to_log(msg):
    # Get the 'toga' logger
    logger = logging.getLogger(LOGGER_ID)
    # Log to both file and console
    logger.info(msg)
