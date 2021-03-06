#!/bin/bash

# Copyright 2016 ASLP@NPU.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: npuichigo@gmail.com (zhangyuchao)

current_working_dir=$(pwd)
voicenet_dir=$(dirname $(dirname $current_working_dir))

stage=1
raw=raw
data=data
config=config
dir=exp/acoustic
add_delta=false
kaldi_format=false
export_graph=true
compute_distortion=true

set -euo pipefail

[ ! -e $data ] && mkdir -p $data
[ ! -e $config ] && mkdir -p $config

# Make train test val data
if [ $stage -le 0 ]; then
  echo "Creating file list with scp format"
  cd ${raw}/prepared_label/ && ${voicenet_dir}/misc/scripts/create_scp.sh label && cd $current_working_dir
  cd ${raw}/prepared_cmp/ && ${voicenet_dir}/misc/scripts/create_scp.sh param && cd $current_working_dir

  echo "Randomly selecting train test val data and create config file"
  python ${voicenet_dir}/misc/scripts/get_random_scp.py

  if $kaldi_format; then
    [ -f $voicenet_dir/misc/scripts/kaldi_path.sh ] && . $voicenet_dir/misc/scripts/kaldi_path.sh;
    for x in train test val; do
    {
      convert-binary-to-matrix "ark:${raw}/prepared_label/label_scp/${x}.scp" "ark,scp:${data}/${x}_label.ark,${data}/${x}_label.scp"
      convert-binary-to-matrix "ark:${raw}/prepared_cmp/param_scp/${x}.scp" "ark,scp:${data}/${x}_param.ark,${data}/${x}_param.scp"
    }
    done

    # Add delta features
    if $add_delta; then
      for x in train test val; do
      {
        add-deltas --delta-window=1 "ark:${data}/${x}_param.ark" "ark,scp:${data}/${x}_param_delta.ark,${data}/${x}_param_delta.scp"
      }
    done
    fi

    # Do CMVN
    compute-cmvn-stats --binary=true scp:${data}/train_label.scp $dir/label_cmvn
    compute-cmvn-stats --binary=true scp:${data}/train_param.scp $dir/param_cmvn
    python $voicenet_dir/misc/scripts/convert_binary_cmvn_to_text.py ${dir}/param_cmvn
  else
    # Tfrecords format
    [ ! -e $data/train ] && mkdir -p $data/train
    [ ! -e $data/valid ] && mkdir -p $data/valid
    [ ! -e $data/test ] && mkdir -p $data/test
    # You should change the dimensions here to match your own dataset
    ./pyqueue_tts.pl -q all.q stage1_log_file python ${voicenet_dir}/src/utils/convert_to_records_parallel.py --input_dim=246 --output_dim=127
  fi
fi

# Train nnet with cross-validation
if [ $stage -le 1 ]; then
  [ ! -e $dir ] && mkdir -p $dir
  [ ! -e $dir/nnet ] && mkdir -p $dir/nnet
  echo "Training nnet"
  ./pyqueue_tts.pl --gpu 1 log_file python $voicenet_dir/src/run_tts.py --save_dir=$dir "$@"
fi

# Decode nnet
if [ $stage -le 2 ]; then
  [ ! -e $dir/test/cmp ] && mkdir -p $dir/test/cmp
  echo "Decoding nnet"
  # Disable gpu for decoding
  CUDA_VISIBLE_DEVICES= TF_CPP_MIN_LOG_LEVEL=1 python $voicenet_dir/src/run_tts.py --decode --save_dir=$dir "$@"
fi

# Vocoder synthesis
if [ $stage -le 3 ]; then
  echo "Synthesizing wav"
  python $voicenet_dir/misc/scripts/world_mlpg/cmvn2dat.py \
       --var=$current_working_dir/var \
       --cmvn=$data/train_cmvn.npz
  python $voicenet_dir/misc/scripts/world_mlpg/parameter_generation.py \
      --out_dir=$dir/test \
      --var_dir=$current_working_dir/var/
  sh $voicenet_dir/misc/scripts/synthesize.sh $dir/test
fi

# Export graph for inference
if [ $stage -le 4 ]; then
  if $export_graph; then
    echo "Exporting graph"
    CUDA_VISIBLE_DEVICES= TF_CPP_MIN_LOG_LEVEL=1 python $voicenet_dir/src/export_inference_graph.py  --output_file=$dir/frozen_acoustic.pb --checkpoint_path=$dir/nnet "$@"
  fi
fi

# Compute Distortion
if [ $stage -le 5 ]; then
  if $compute_distortion; then
    echo "Compute dirtortion and write to exp/acoustic/dirtortion.txt"
    [ ! -e $dir/reference/cmp ] && mkdir -p $dir/reference/cmp
    cat $current_working_dir/$config/test.lst \
        | awk '{print $2}' \
        | sed "s/label/cmp/g" \
        | sed "s/.lab/.cmp/g" \
        | xargs -i cp {} $dir/reference/cmp
    python $voicenet_dir/misc/scripts/world_mlpg/parameter_generation.py \
        --out_dir=$current_working_dir/$dir/reference \
        --var_dir=$current_working_dir/var/
    sh $voicenet_dir/misc/scripts/synthesize.sh $dir/reference
    $voicenet_dir/misc/scripts/getscp.sh \
        $dir/test/cmp \
        $dir/reference/cmp \
        $dir/test_file.scp \
        0
    python $voicenet_dir/misc/scripts/compute_distortion.py \
        $dir/test_file.scp \
        $dir/reference \
        $dir/test > $dir/dirtortion.txt
  fi
fi
