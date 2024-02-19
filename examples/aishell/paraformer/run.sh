#!/usr/bin/env bash

workspace=`pwd`

# machines configuration
CUDA_VISIBLE_DEVICES="0,1"
gpu_num=2
gpu_inference=true  # Whether to perform gpu decoding, set false for cpu decoding
# for gpu decoding, inference_nj=ngpu*njob; for cpu decoding, inference_nj=njob
njob=1

# general configuration
feats_dir="../DATA" #feature output dictionary
exp_dir="."
lang=zh
token_type=char
stage=0
stop_stage=5

# feature configuration
nj=64

# data
raw_data=../raw_data
data_url=www.openslr.org/resources/33

# exp tag
tag="exp1"

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train
valid_set=dev
test_sets="dev test"

asr_config=train_asr_paraformer_conformer_12e_6d_2048_256.yaml
model_dir="baseline_$(basename "${asr_config}" .yaml)_${lang}_${token_type}_${tag}"

#inference_config=conf/decode_asr_transformer_noctc_1best.yaml
#inference_asr_model=valid.acc.ave_10best.pb

## you can set gpu num for decoding here
#gpuid_list=$CUDA_VISIBLE_DEVICES  # set gpus for decoding, the same as training stage by default
#ngpu=$(echo $gpuid_list | awk -F "," '{print NF}')
#
#if ${gpu_inference}; then
#    inference_nj=$[${ngpu}*${njob}]
#    _ngpu=1
#else
#    inference_nj=$njob
#    _ngpu=0
#fi

if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data Download"
    local/download_and_untar.sh ${raw_data} ${data_url} data_aishell
    local/download_and_untar.sh ${raw_data} ${data_url} resource_aishell
fi

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    echo "stage 0: Data preparation"
    # Data preparation
    local/aishell_data_prep.sh ${raw_data}/data_aishell/wav ${raw_data}/data_aishell/transcript ${feats_dir}
    for x in train dev test; do
        cp ${feats_dir}/data/${x}/text ${feats_dir}/data/${x}/text.org
        paste -d " " <(cut -f 1 -d" " ${feats_dir}/data/${x}/text.org) <(cut -f 2- -d" " ${feats_dir}/data/${x}/text.org | tr -d " ") \
            > ${feats_dir}/data/${x}/text
        utils/text2token.py -n 1 -s 1 ${feats_dir}/data/${x}/text > ${feats_dir}/data/${x}/text.org
        mv ${feats_dir}/data/${x}/text.org ${feats_dir}/data/${x}/text

        # convert wav.scp text to jsonl
        scp_file_list_arg="++scp_file_list='[\"${feats_dir}/data/${x}/wav.scp\",\"${feats_dir}/data/${x}/text\"]'"
        python ../../../funasr/datasets/audio_datasets/scp2jsonl.py \
        ++data_type_list='["source", "target"]' \
        ++jsonl_file_out=${feats_dir}/data/${x}/audio_datasets.jsonl \
        ${scp_file_list_arg}
    done
fi

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    echo "stage 1: Feature and CMVN Generation"
#    utils/compute_cmvn.sh --fbankdir ${feats_dir}/data/${train_set} --cmd "$train_cmd" --nj $nj --feats_dim ${feats_dim} --config_file "$asr_config" --scale 1.0
    python ../../../funasr/bin/compute_audio_cmvn.py \
    --config-path "${workspace}" \
    --config-name "${asr_config}" \
    ++train_data_set_list="${feats_dir}/data/${train_set}/audio_datasets.jsonl" \
    ++cmvn_file="${feats_dir}/data/${train_set}/cmvn.json" \
    ++dataset_conf.num_workers=$nj
fi

token_list=${feats_dir}/data/${lang}_token_list/$token_type/tokens.txt
echo "dictionary: ${token_list}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    echo "stage 2: Dictionary Preparation"
    mkdir -p ${feats_dir}/data/${lang}_token_list/$token_type/
   
    echo "make a dictionary"
    echo "<blank>" > ${token_list}
    echo "<s>" >> ${token_list}
    echo "</s>" >> ${token_list}
    utils/text2token.py -s 1 -n 1 --space "" ${feats_dir}/data/$train_set/text | cut -f 2- -d" " | tr " " "\n" \
        | sort | uniq | grep -a -v -e '^\s*$' | awk '{print $0}' >> ${token_list}
    echo "<unk>" >> ${token_list}
fi

# LM Training Stage
if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: LM Training"
fi

# ASR Training Stage
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
echo "stage 4: ASR Training"

  torchrun \
  --nnodes 1 \
  --nproc_per_node ${gpu_num} \
  ../../../funasr/bin/train.py \
  --config-path "${workspace}" \
  --config-name "${asr_config}" \
  ++train_data_set_list="${feats_dir}/data/${train_set}/audio_datasets.jsonl" \
  ++cmvn_file="${feats_dir}/data/${train_set}/am.mvn" \
  ++token_list="${token_list}" \
  ++output_dir="${exp_dir}/exp/${model_dir}"
fi

#
## Testing Stage
#if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
#    echo "stage 5: Inference"
#    for dset in ${test_sets}; do
#        asr_exp=${exp_dir}/exp/${model_dir}
#        inference_tag="$(basename "${inference_config}" .yaml)"
#        _dir="${asr_exp}/${inference_tag}/${inference_asr_model}/${dset}"
#        _logdir="${_dir}/logdir"
#        if [ -d ${_dir} ]; then
#            echo "${_dir} is already exists. if you want to decode again, please delete this dir first."
#            exit 0
#        fi
#        mkdir -p "${_logdir}"
#        _data="${feats_dir}/data/${dset}"
#        key_file=${_data}/${scp}
#        num_scp_file="$(<${key_file} wc -l)"
#        _nj=$([ $inference_nj -le $num_scp_file ] && echo "$inference_nj" || echo "$num_scp_file")
#        split_scps=
#        for n in $(seq "${_nj}"); do
#            split_scps+=" ${_logdir}/keys.${n}.scp"
#        done
#        # shellcheck disable=SC2086
#        utils/split_scp.pl "${key_file}" ${split_scps}
#        _opts=
#        if [ -n "${inference_config}" ]; then
#            _opts+="--config ${inference_config} "
#        fi
#        ${infer_cmd} --gpu "${_ngpu}" --max-jobs-run "${_nj}" JOB=1:"${_nj}" "${_logdir}"/asr_inference.JOB.log \
#            python -m funasr.bin.asr_inference_launch \
#                --batch_size 1 \
#                --ngpu "${_ngpu}" \
#                --njob ${njob} \
#                --gpuid_list ${gpuid_list} \
#                --data_path_and_name_and_type "${_data}/${scp},speech,${type}" \
#                --cmvn_file ${feats_dir}/data/${train_set}/cmvn/am.mvn \
#                --key_file "${_logdir}"/keys.JOB.scp \
#                --asr_train_config "${asr_exp}"/config.yaml \
#                --asr_model_file "${asr_exp}"/"${inference_asr_model}" \
#                --output_dir "${_logdir}"/output.JOB \
#                --mode paraformer \
#                ${_opts}
#
#        for f in token token_int score text; do
#            if [ -f "${_logdir}/output.1/1best_recog/${f}" ]; then
#                for i in $(seq "${_nj}"); do
#                    cat "${_logdir}/output.${i}/1best_recog/${f}"
#                done | sort -k1 >"${_dir}/${f}"
#            fi
#        done
#        python utils/proce_text.py ${_dir}/text ${_dir}/text.proc
#        python utils/proce_text.py ${_data}/text ${_data}/text.proc
#        python utils/compute_wer.py ${_data}/text.proc ${_dir}/text.proc ${_dir}/text.cer
#        tail -n 3 ${_dir}/text.cer > ${_dir}/text.cer.txt
#        cat ${_dir}/text.cer.txt
#    done
#fi
#
## Prepare files for ModelScope fine-tuning and inference
#if [ ${stage} -le 6 ] && [ ${stop_stage} -ge 6 ]; then
#    echo "stage 6: ModelScope Preparation"
#    cp ${feats_dir}/data/${train_set}/cmvn/am.mvn ${exp_dir}/exp/${model_dir}/am.mvn
#    vocab_size=$(cat ${token_list} | wc -l)
#    python utils/gen_modelscope_configuration.py \
#        --am_model_name $inference_asr_model \
#        --mode paraformer \
#        --model_name paraformer \
#        --dataset aishell \
#        --output_dir $exp_dir/exp/$model_dir \
#        --vocab_size $vocab_size \
#        --nat _nat \
#        --tag $tag
#fi