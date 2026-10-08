#include <stdio.h>
#include <llama/llama.h>
int main(void) {
 struct llama_context_params p=llama_context_default_params();
 printf("{\"n_batch\":%u,\"n_ubatch\":%u,\"n_ctx\":%u,\"n_outputs_max\":%u,\"flash_attention\":%d,\"type_k\":%d,\"type_v\":%d}\n",p.n_batch,p.n_ubatch,p.n_ctx,p.n_outputs_max,p.flash_attn_type,p.type_k,p.type_v);
 return 0;
}
