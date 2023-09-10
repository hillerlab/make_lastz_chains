"""Class to manage pipeline parameters."""
import os
import json
from constants import Constants as Const


class PipelineParameters:
    def __init__(self, args):
        self.target_name = args.target_name
        self.query_name = args.query_name
        self.project_dir = args.project_dir
        self.seq_1_dir = os.path.abspath(os.path.join(self.project_dir, Const.TARGET_SEQ_FILENAME))
        self.seq_1_len = os.path.abspath(os.path.join(self.project_dir, Const.TARGET_CHROM_SIZES_FILENAME))
        self.seq_2_dir = os.path.abspath(os.path.join(self.project_dir, Const.QUERY_SEQ_FILENAME))
        self.seq_2_len = os.path.abspath(os.path.join(self.project_dir, Const.QUERY_CHROM_SIZES_FILENAME))

        self.lastz_y = args.lastz_y
        self.lastz_h = args.lastz_h
        self.lastz_l = args.lastz_l
        self.lastz_k = args.lastz_k

        self.seq_1_chunk = args.seq1_chunk
        self.seq_1_lap = args.seq1_lap
        self.seq_1_limit = args.seq1_limit
        self.seq_2_chunk = args.seq2_chunk
        self.seq_2_lap = args.seq2_lap
        self.seq_2_limit = args.seq2_limit

        self.fill_chain = args.fill_chain
        self.fill_unmask = args.fill_unmask
        self.fill_chain_min_score = args.fill_chain_min_score
        self.fill_insert_chain_min_score = args.fill_insert_chain_min_score

        self.fill_gap_max_size_t = args.fill_gap_max_size_t
        self.fill_gap_max_size_q = args.fill_gap_max_size_q
        self.fill_gap_min_size_t = args.fill_gap_min_size_t
        self.fill_gap_min_size_q = args.fill_gap_min_size_q

        self.fill_lastz_k = args.fill_lastz_k
        self.fill_lastz_l = args.fill_lastz_l

        self.fill_memory = args.fill_memory
        self.fill_prepare_memory = args.fill_prepare_memory
        # self.chaining_queue = args.chaining_queue
        self.chaining_memory = args.chaining_memory
        self.clean_chain = args.clean_chain
        self.chain_clean_memory = args.chain_clean_memory
        self.clean_chain_parameters = args.clean_chain_parameters

        # perform sanity checks and quit if something is wrong
        self.__sanity_checks()

    def __sanity_checks(self):
        # TODO: implement this method
        pass

    def dump_to_json(self, directory):
        json_file_path = os.path.join(directory, Const.PARAMS_JSON_FILENAME)
        attributes = vars(self)  # get all attributes as a dictionary
        with open(json_file_path, "w") as f:
            json.dump(attributes, f, indent=4)
