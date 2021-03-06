// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
* @file
* bfs_app.cu
*
* @brief Gunrock Breadth-first search implementation
*/

#include <stdio.h>
#include <gunrock/gunrock.h>

// Graph construction utils
#include <gunrock/graphio/market.cuh>

// BFS includes
#include <gunrock/app/bfs/bfs_enactor.cuh>
#include <gunrock/app/bfs/bfs_problem.cuh>
#include <gunrock/app/bfs/bfs_functor.cuh>

// MGPU include
#include <moderngpu.cuh>

using namespace gunrock;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::bfs;

/**
* Performance/Evaluation statistics
*/
struct Stats
{
  const char *name;
  Statistic rate;
  Statistic search_depth;
  Statistic redundant_work;
  Statistic duty;

  Stats() : name(NULL), rate(), search_depth(), redundant_work(), duty() {}
  Stats(const char *name) : name(name), rate(), search_depth(), redundant_work(), duty() {}
};

/**
* @brief Displays timing and correctness statistics
*
* @tparam MARK_PREDECESSORS
* @tparam VertexId
* @tparam Value
* @tparam SizeT
*
* @param[in] stats Reference to the Stats object defined in RunTests
* @param[in] src Source node where BFS starts
* @param[in] h_labels Host-side vector stores computed labels for validation
* @param[in] graph Reference to the CSR graph we process on
* @param[in] elapsed Total elapsed kernel running time
* @param[in] search_depth Maximum search depth of the BFS algorithm
* @param[in] total_queued Total element queued in BFS kernel running process
* @param[in] avg_duty Average duty of the BFS kernels
*/
template<
  bool     MARK_PREDECESSORS,
  typename VertexId,
  typename Value,
  typename SizeT>
void DisplayStats(
  Stats     &stats,
  VertexId  src,
  VertexId  *h_labels,
  const Csr<VertexId, Value, SizeT> &graph,
  double    elapsed,
  VertexId  search_depth,
  long long total_queued,
  double    avg_duty)
{
  // Compute nodes and edges visited
  SizeT edges_visited = 0;
  SizeT nodes_visited = 0;
  for (VertexId i = 0; i < graph.nodes; ++i)
  {
    if (h_labels[i] > -1)
    {
      ++nodes_visited;
      edges_visited += graph.row_offsets[i+1] - graph.row_offsets[i];
    }
  }

  double redundant_work = 0.0;
  if (total_queued > 0)
  {
    // measure duplicate edges put through queue
    redundant_work = ((double) total_queued - edges_visited) / edges_visited;
  }

  redundant_work *= 100;

  // Display test name
  printf("[%s] finished.", stats.name);

  // Display statistics
  if (nodes_visited < 5) printf("Fewer than 5 vertices visited.\n");
  else
  {
    // Display the specific sample statistics
    double m_teps = (double) edges_visited / (elapsed * 1000.0);
    printf("\nelapsed: %.3f ms, rate: %.3f MiEdges/s", elapsed, m_teps);
    if (search_depth != 0) printf(", search_depth: %lld", (long long) search_depth);
    if (avg_duty != 0)     printf("\n avg CTA duty: %.2f%%", avg_duty * 100);
    printf("\nsource_node: %lld, nodes_visited: %lld, edges visited: %lld",
      (long long) src, (long long) nodes_visited, (long long) edges_visited);
    if (total_queued > 0)   printf(", total queued: %lld", total_queued);
    if (redundant_work > 0) printf(", redundant work: %.2f%%", redundant_work);
    printf("\n");
  }
}

/**
* @brief Run BFS tests
*
* @tparam VertexId
* @tparam Value
* @tparam SizeT
* @tparam MARK_PREDECESSORS
* @tparam ENABLE_IDEMPOTENCE
*
* @param[out] ggraph_out Pointer to the output CSR graph 
* @param[in] ggraph_in Reference to the CSR graph we process on
* @param[in] src Source node where BFS starts
* @param[in] max_grid_size Maximum CTA occupancy
* @param[in] num_gpus Number of GPUs
* @param[in] max_queue_sizing Scaling factor used in edge mapping
* @param[in] context Reference to CudaContext used by moderngpu functions
*
*/
template <
  typename VertexId,
  typename Value,
  typename SizeT,
  bool MARK_PREDECESSORS,
  bool ENABLE_IDEMPOTENCE>
void run_bfs(
  GunrockGraph *ggraph_out,
  const  Csr<VertexId, Value, SizeT> &ggraph_in,
  const  VertexId src,
  int    max_grid_size,
  int    num_gpus,
  double max_queue_sizing,
  CudaContext& context)
{
  // Preparations
  typedef BFSProblem<
    VertexId,
    SizeT,
    Value,
    MARK_PREDECESSORS,
    ENABLE_IDEMPOTENCE,
    (MARK_PREDECESSORS && ENABLE_IDEMPOTENCE)> Problem;

  // Allocate host-side label array for gpu-computed results
  VertexId *h_labels = (VertexId*)malloc(sizeof(VertexId) * ggraph_in.nodes);
  VertexId *h_preds = NULL;
  if (MARK_PREDECESSORS)
  {
    //h_preds = (VertexId*)malloc(sizeof(VertexId) * ggraph_in.nodes);
  }

  // Allocate BFS enactor map
  BFSEnactor<false> bfs_enactor(false);

  // Allocate problem on GPU
  Problem *csr_problem = new Problem;
  util::GRError(csr_problem->Init(
    false,
    ggraph_in,
    num_gpus),
    "Problem BFS Initialization Failed", __FILE__, __LINE__);

  Stats *stats = new Stats("GPU Breadth-first search");

  long long total_queued = 0;
  VertexId search_depth = 0;
  double avg_duty = 0.0;

  // Perform BFS
  GpuTimer gpu_timer;

  util::GRError(csr_problem->Reset(
    src, bfs_enactor.GetFrontierType(), max_queue_sizing),
    "BFS Problem Data Reset Failed", __FILE__, __LINE__);

  gpu_timer.Start();
  util::GRError(bfs_enactor.template Enact<Problem>(
    context, csr_problem, src, max_grid_size),
    "BFS Problem Enact Failed", __FILE__, __LINE__);
  gpu_timer.Stop();

  bfs_enactor.GetStatistics(total_queued, search_depth, avg_duty);

  float elapsed = gpu_timer.ElapsedMillis();

  // Copy out results back to Host
  util::GRError(csr_problem->Extract(h_labels, h_preds),
    "BFS Problem Data Extraction Failed", __FILE__, __LINE__);

  // label per node to GunrockGraph struct
  ggraph_out->node_values = (int*)&h_labels[0];

  // Display Stats
  DisplayStats<MARK_PREDECESSORS>(
    *stats,
    src,
    h_labels,
    ggraph_in,
    elapsed,
    search_depth,
    total_queued,
    avg_duty);

  // Clean up
  delete stats;
  if (csr_problem) delete csr_problem;
  //if (h_preds)     free(h_preds);

  cudaDeviceSynchronize();
}

/**
 * @brief dispatch function to handle data_types
 *
 * @param[out] ggraph_out GunrockGraph type output
 * @param[in]  ggraph_in  GunrockGraph type input graph
 * @param[in]  bfs_config bfs specific configurations
 * @param[in]  data_type  bfs data_type configurations
 * @param[in]  context    moderngpu context
 */
void dispatch_bfs(
  GunrockGraph       *ggraph_out,
  const GunrockGraph *ggraph_in,
  GunrockConfig      bfs_config,
  GunrockDataType    data_type,
  CudaContext&       context)
{
  switch (data_type.VTXID_TYPE) {
  case VTXID_INT: {
    switch (data_type.SIZET_TYPE) {
    case SIZET_INT: {
        switch (data_type.VALUE_TYPE) {
        case VALUE_INT: {
          // template type = <int, int, int>
          // build input csr format graph
          Csr<int, int, int> csr_graph(false);
          csr_graph.nodes = ggraph_in->num_nodes;
          csr_graph.edges = ggraph_in->num_edges;
          csr_graph.row_offsets    = (int*)ggraph_in->row_offsets;
          csr_graph.column_indices = (int*)ggraph_in->col_indices;

          // default configurations
          int   src_node      = 0;       //!< default source vertex to start
          int   num_gpus      = 1;       //!< number of GPUs for multi-gpu enactor to use
          int   max_grid_size = 0;       //!< maximum grid size (0: leave it up to the enactor)
          bool  mark_pred     = false;   //!< whether to mark predecessor or not
          bool  idempotence   = false;   //!< whether or not to enable idempotence
          float max_queue_sizing = 1.0f; //!< maximum size scaling factor for work queues

          // determine source vertex to start bfs
          switch (bfs_config.src_mode)
          {
            case randomize:
            {
              src_node = graphio::RandomNode(csr_graph.nodes);
              break;
            }
            case largest_degree:
            {
                int max_deg = 0;
                src_node = csr_graph.GetNodeWithHighestDegree(max_deg);
                break;
            }
            case manually:
            {
              src_node = bfs_config.src_node;
              break;
            }
            default:
            {
              src_node = 0;
              break;
            }
          }
          mark_pred        = bfs_config.mark_pred;
          idempotence      = bfs_config.idempotence;
          max_queue_sizing = bfs_config.queue_size;

          if (mark_pred)
          {
            if (idempotence)
            {
              run_bfs<int, int, int, true, true>(
                ggraph_out,
                csr_graph,
                src_node,
                max_grid_size,
                num_gpus,
                max_queue_sizing,
                context);
            }
            else
            {
              run_bfs<int, int, int, true, false>(
                ggraph_out,
                csr_graph,
                src_node,
                max_grid_size,
                num_gpus,
                max_queue_sizing,
                context);
            }
          }
          else
          {
            if (idempotence)
            {
              run_bfs<int, int, int, false, true>(
                ggraph_out,
                csr_graph,
                src_node,
                max_grid_size,
                num_gpus,
                max_queue_sizing,
                context);
            }
            else
            {
              run_bfs<int, int, int, false, false>(
                ggraph_out,
                csr_graph,
                src_node,
                max_grid_size,
                num_gpus,
                max_queue_sizing,
                context);
            }
          }
          // reset for free memory
          csr_graph.row_offsets    = NULL;
          csr_graph.column_indices = NULL;
          break;
      }
      case VALUE_UINT: {
        // template type = <int, uint, int>
        // not yet support
        printf("Not Yet Support This DataType Combination.\n");
        break;
      }
      case VALUE_FLOAT: {
        // template type = <int, float, int>
        // not yet support
        printf("Not Yet Support This DataType Combination.\n");
        break;
      }
      }
    break;
    }
    }
    break;
  }
  }
}

/*
* @brief gunrock_bfs function
*
* @param[out] ggraph_out output subgraph of bfs problem
* @param[in]  ggraph_in  input graph need to process on
* @param[in]  bfs_config gunrock primitive specific configurations
* @param[in]  data_type  gunrock datatype struct
*/
void gunrock_bfs_func(
  GunrockGraph       *ggraph_out,
  const GunrockGraph *ggraph_in,
  GunrockConfig      bfs_config,
  GunrockDataType    data_type)
{
  // moderngpu preparations
  int device = 0;
  device = bfs_config.device;
  ContextPtr context = mgpu::CreateCudaDevice(device);

  // launch dispatch function
  dispatch_bfs(ggraph_out, ggraph_in, bfs_config, data_type, *context);
}

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
