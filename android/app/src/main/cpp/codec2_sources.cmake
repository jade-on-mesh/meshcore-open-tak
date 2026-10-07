# MeshCore Open VOX: only the Codec2 speech codec. The FreeDV modems and LDPC
# tables in third_party/codec2/src are not needed for voice messages and are
# very slow to compile, so they are left out.
# Keep in sync with third_party/codec2/codec2.podspec.
set(CODEC2_SOURCES
    dump.c
    lpc.c
    nlp.c
    postfilter.c
    sine.c
    codec2.c
    codec2_fft.c
    kiss_fft.c
    kiss_fftr.c
    interp.c
    lsp.c
    mbest.c
    newamp1.c
    phase.c
    quantise.c
    pack.c
    codebook.c
    codebookd.c
    codebookjmv.c
    codebookge.c
    codebooknewamp1.c
    codebooknewamp1_energy.c
    codebooknewamp2.c
    codebooknewamp2_energy.c
)
