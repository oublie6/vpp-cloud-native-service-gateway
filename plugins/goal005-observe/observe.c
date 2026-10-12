#include <vnet/vnet.h>
#include <vnet/plugin/plugin.h>
#include <vnet/feature/feature.h>
#include <vnet/ip/ip4_packet.h>
#include <vnet/ip/ip.h>
#include <vlibapi/api.h>
#include <vlibmemory/api.h>
#include <vnet/api_errno.h>

#include <observe.api_enum.h>
#include <observe.api_types.h>
#define REPLY_MSG_ID_BASE goal005_main.msg_id_base
#include <vlibapi/api_helper_macros.h>

typedef struct
{
  u16 msg_id_base;
} goal005_main_t;

static goal005_main_t goal005_main;

VLIB_PLUGIN_REGISTER () = {
  .version = "0.1.0",
  .description = "Goal 005 IPv4 feature observation",
};

typedef struct
{
  u32 sw_if_index;
  u32 next_index;
  ip4_address_t src;
  ip4_address_t dst;
} goal005_trace_t;

static u8 *
format_goal005_trace (u8 *s, va_list *args)
{
  CLIB_UNUSED (vlib_main_t *vm) = va_arg (*args, vlib_main_t *);
  CLIB_UNUSED (vlib_node_t *node) = va_arg (*args, vlib_node_t *);
  goal005_trace_t *t = va_arg (*args, goal005_trace_t *);
  return format (s, "goal005-observe rx %u %U -> %U next %u", t->sw_if_index,
                 format_ip4_address, &t->src, format_ip4_address, &t->dst,
                 t->next_index);
}

/* 这是观察计数，不代表错误；show errors 中按 info severity 展示。 */
static vlib_error_desc_t goal005_counters[] = {
  { .name = "observed", .desc = "observed IPv4 packets",
    .severity = VL_COUNTER_SEVERITY_INFO },
};

VLIB_NODE_FN (goal005_observe_node) (vlib_main_t *vm,
                                     vlib_node_runtime_t *node,
                                     vlib_frame_t *frame)
{
  u32 *from = vlib_frame_vector_args (frame);
  u32 n = frame->n_vectors;
  u16 nexts[VLIB_FRAME_SIZE];

  for (u32 i = 0; i < n; i++)
    {
      vlib_buffer_t *b = vlib_get_buffer (vm, from[i]);
      ip4_header_t *ip = vlib_buffer_get_current (b);
      u32 next = 0;

      /* feature arc 决定后继；本节点不改写也不释放 buffer。 */
      vnet_feature_next (&next, b);
      nexts[i] = next;
      if (PREDICT_FALSE ((b->flags & VLIB_BUFFER_IS_TRACED) &&
                         (node->flags & VLIB_NODE_FLAG_TRACE)))
        {
          goal005_trace_t *t = vlib_add_trace (vm, node, b, sizeof (*t));
          t->sw_if_index = vnet_buffer (b)->sw_if_index[VLIB_RX];
          t->next_index = next;
          t->src = ip->src_address;
          t->dst = ip->dst_address;
        }
    }
  vlib_node_increment_counter (vm, node->node_index, 0, n);
  vlib_buffer_enqueue_to_next (vm, node, from, nexts, n);
  return n;
}

VLIB_REGISTER_NODE (goal005_observe_node) = {
  .name = "goal005-observe",
  .vector_size = sizeof (u32),
  .format_trace = format_goal005_trace,
  .n_errors = ARRAY_LEN (goal005_counters),
  .error_counters = goal005_counters,
};

VNET_FEATURE_INIT (goal005_observe, static) = {
  .arc_name = "ip4-unicast",
  .node_name = "goal005-observe",
};

static void
vl_api_goal005_observe_enable_disable_t_handler (
  vl_api_goal005_observe_enable_disable_t *mp)
{
  vl_api_goal005_observe_enable_disable_reply_t *rmp;
  int rv;
  u32 sw_if_index = clib_net_to_host_u32 (mp->sw_if_index);
  vnet_main_t *vnm = vnet_get_main ();

  if (pool_is_free_index (vnm->interface_main.sw_interfaces, sw_if_index))
    rv = VNET_API_ERROR_INVALID_SW_IF_INDEX;
  else
    rv = vnet_feature_enable_disable ("ip4-unicast", "goal005-observe",
                                      sw_if_index, mp->enable_disable, 0, 0);
  REPLY_MACRO (VL_API_GOAL005_OBSERVE_ENABLE_DISABLE_REPLY);
}

#include <observe.api.c>

static clib_error_t *
goal005_init (vlib_main_t *vm)
{
  goal005_main.msg_id_base = setup_message_id_table ();
  return 0;
}
VLIB_INIT_FUNCTION (goal005_init);
