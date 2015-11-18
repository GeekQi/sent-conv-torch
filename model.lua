require 'torch'
require 'nn'
require 'nngraph'
local HighwayMLP = require 'highway_mlp'
local HighwayConv = require 'highway_conv'

local ModelBuilder = torch.class('ModelBuilder')

function ModelBuilder.init_cmd(cmd)
  cmd:option('-vocab_size', 18766, 'Vocab size')
  cmd:option('-vec_size', 300, 'word2vec vector size')
  cmd:option('-max_sent', 59, 'maximum sentence length')

  cmd:option('-num_feat_maps', 100, 'Number of feature maps after 1st convolution')
  cmd:option('-kernel1', 3, 'Kernel size of convolution 1')
  cmd:option('-kernel2', 4, 'Kernel size of convolution 2')
  cmd:option('-kernel3', 5, 'Kernel size of convolution 3')
  cmd:option('-skip_kernel', 0, 'Use skip kernel')
  cmd:option('-dropout_p', 0.5, 'p for dropout')
  cmd:option('-highway_mlp', 0, 'Number of highway MLP layers')
  cmd:option('-highway_conv_layers', 0, 'Number of highway MLP layers')
  cmd:option('-num_classes', 2, 'Number of output classes')
end

function ModelBuilder:make_net(w2v, opts)
  if opts.cudnn == 1 then
    require 'cudnn'
    require 'cunn'
  end

  local input = nn.Identity()()

  local lookup = nn.LookupTable(opts.vocab_size, opts.vec_size)
  if opts.model_type == 'static' or opts.model_type == 'nonstatic' then
    lookup.weight:copy(w2v)
  else
    lookup.weight:uniform(-0.25, 0.25)
  end
  -- padding should always be 0
  lookup.weight[1]:zero()

  local lookup_layer = lookup(input)

  -- kernels is an array of kernel sizes
  local kernels = {opts.kernel1, opts.kernel2, opts.kernel3}
  local layer1 = {}
  for i = 1, #kernels do
    local conv
    local conv_layer
    local max_time
    if opts.cudnn == 1 then
      conv = cudnn.SpatialConvolution(1, opts.num_feat_maps, opts.vec_size, kernels[i])

      if opts.highway_conv_layers > 0 then
        local highway_conv = HighwayConv.conv(opts.vec_size, opts.max_sent, kernels[i], opts.highway_conv_layers)
        conv_layer = nn.Reshape(opts.num_feat_maps, opts.max_sent-kernels[i]+1, true)(
          conv(nn.Reshape(1, opts.max_sent, opts.vec_size, true)(
          highway_conv(lookup_layer))))
        max_time = nn.Max(3)(conv_layer)
      else
        conv_layer = nn.Reshape(opts.num_feat_maps, opts.max_sent-kernels[i]+1, true)(conv(nn.Reshape(1, opts.max_sent, opts.vec_size, true)(lookup_layer)))
        max_time = nn.Max(3)(cudnn.ReLU()(conv_layer))
      end

    else
      conv = nn.TemporalConvolution(opts.vec_size, opts.num_feat_maps, kernels[i])
      conv_layer = conv(lookup_layer)
      --max_time = nn.Max(3)(nn.Transpose({2,3})(nn.ReLU()(conv_layer))) -- max over time
      max_time = nn.Max(2)(nn.ReLU()(conv_layer)) -- max over time
    end

    conv.weight:uniform(-0.01, 0.01)
    conv.bias:zero()
    table.insert(layer1, max_time)
  end

  if opts.skip_kernel > 0 then
    -- skip kernel
    local kern_size = 5 -- fix for now
    local skip_conv = cudnn.SpatialConvolution(1, opts.num_feat_maps, opts.vec_size, kern_size)
    skip_conv.name = 'skip_conv'
    skip_conv.weight:uniform(-0.01, 0.01)
    -- skip center for now
    skip_conv.weight:select(3,3):zero()
    skip_conv.bias:zero()
    local skip_conv_layer = nn.Reshape(opts.num_feat_maps, opts.max_sent-kern_size+1, true)(skip_conv(nn.Reshape(1, opts.max_sent, opts.vec_size, true)(lookup_layer)))
    table.insert(layer1, nn.Max(3)(cudnn.ReLU()(skip_conv_layer)))
  end

  local conv_layer_concat
  if #layer1 > 1 then
    conv_layer_concat = nn.JoinTable(2)(layer1)
  else
    conv_layer_concat = layer1[1]
  end

  local last_layer = conv_layer_concat
  if opts.highway_mlp > 0 then
    -- use highway layers
    local highway = HighwayMLP.mlp((#layer1) * opts.num_feat_maps, opts.highway_layers)
    last_layer = highway(conv_layer_concat)
  end

  -- simple MLP layer
  local linear = nn.Linear((#layer1) * opts.num_feat_maps, opts.num_classes)
  linear.weight:normal():mul(0.01)
  linear.bias:zero()

  local softmax
  if opts.cudnn == 1 then
    softmax = cudnn.LogSoftMax()
  else
    softmax = nn.LogSoftMax()
  end

  local output = softmax(linear(nn.Dropout(opts.dropout_p)(last_layer))) 
  model = nn.gModule({input}, {output})
  return model
end

function ModelBuilder:get_layer(model, name)
  local named_layer
  function get_layer(layer)
    if torch.typename(layer) == name or layer.name == name then
      named_layer = layer
    end
  end

  model:apply(get_layer)
  return named_layer
end

return ModelBuilder
