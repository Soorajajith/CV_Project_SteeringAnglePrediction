require 'torch'
require 'cutorch'
require 'optim'
require 'os'
require 'optim'
require 'xlua'
require'lfs'
names = {}
local END = 12
for file in lfs.dir[[/home/pratheeksha/CV_Project_SteeringAnglePrediction/data_/train_images_center/]] do
    --if lfs.attributes(file,"mode") == "file" then 
    -- print(file,string.sub(file,0,END))
    name = string.sub(file,0,END)
    --end
    names[name] = file
end

-- torch.save('names.t7',names)
function rgb2gray(im)
	-- Image.rgb2y uses a different weight mixture

	local dim, w, h = im:size()[1], im:size()[2], im:size()[3]
	if dim ~= 3 then
		 print('<error> expected 3 channels')
		 return im
	end

	-- a cool application of tensor:select
	local r = im:select(1, 1)
	local g = im:select(1, 2)
	local b = im:select(1, 3)

	local z = torch.Tensor(w, h):zero()

	-- z = z + 0.21r
	z = z:add(0.21, r)
	z = z:add(0.72, g)
	z = z:add(0.07, b)
	return z
end
require 'cunn'
-- require 'cudnn' -- faster convolutions

--[[
--  Hint:  Plot as much as you can.
--  Look into torch wiki for packages that can help you plot.
--]]

-- local trainData = torch.load(DATA_PATH..'train.t7')
-- local testData = torch.load(DATA_PATH..'test.t7')
local csv2tensor = require 'csv2tensor'
local trainData, column_names = csv2tensor.load("/home/pratheeksha/CV_Project_SteeringAnglePrediction/data_/res.csv") 

local tnt = require 'torchnet'
local image = require 'image'
local optParser = require 'opts'
local opt = optParser.parse(arg)

local WIDTH, HEIGHT = 320,140
local DATA_PATH = (opt.data ~= '' and opt.data or './data_/')

torch.setdefaulttensortype('torch.DoubleTensor')

torch.manualSeed(opt.manualSeed)

function resize(img)
    modimg = img[{{},{200,480},{}}]
    return image.scale(modimg,WIDTH,HEIGHT)
end
function yuv(img)
    return image.rgb2yuv(img)
end
function norm(img)
	new = img/255
	new = new - torch.mean(new)
	return new	
end
function transformInput(inp)
    f = tnt.transform.compose{
        [1] = resize,
	[2] = yuv,
	[3] = norm
    }
    return f(inp)
end

function getTrainSample(dataset, idx)
    r = dataset[idx]
    file = string.format("%19d.jpg", r[1])
    name = string.sub(file,1,END)
    -- print(file,names[name])
    return transformInput(image.load(DATA_PATH .. 'train_images_center/'..names[name]))
end

function getTrainLabel(dataset, idx)
    -- return torch.LongTensor{dataset[idx][9] + 1}
	val = dataset[idx][2]
	cl = 3
	if (val<=-0.75) then
		if (val>=-2.25) then 
			cl = 2
		else
			cl = 1
		end
	else
		if (val<=0.50) then
			cl = 3
		elseif (val<=2.25) then
			cl = 4
		else
			cl = 5
		end
	end
	return torch.LongTensor{val}
    -- return torch.DoubleTensor{100.00*dataset[idx][2]}
end

function getTestSample(dataset, idx)
    r = dataset[idx]
    file = DATA_PATH .. "/test_images/" .. string.format("%05d.ppm", r[1])
    return transformInput(image.load(file))
end

function getIterator(dataset)
    --[[
    -- Hint:  Use ParallelIterator for using multiple CPU cores
    --]]
	return  tnt.DatasetIterator{
    	--dataset =  tnt.ShuffleDataset{        
	dataset = tnt.BatchDataset{
            batchsize = opt.batchsize,
            dataset = dataset
        }
    }
--}
end


trainDataset = tnt.SplitDataset{
    partitions = {train=0.9, val=0.1},
    initialpartition = 'train',
   
    dataset = tnt.ShuffleDataset{
        dataset = tnt.ListDataset{
            list = torch.range(1, trainData:size(1)):long(),
            load = function(idx)
                return {
                    input =  getTrainSample(trainData, idx),
                    target = getTrainLabel(trainData, idx)
                }
            end
        }
    }
}

--[[testDataset = tnt.ListDataset{
    list = torch.range(1, testData:size(1)):long(),
    load = function(idx)
        return {
            input = getTestSample(testData, idx),
            sampleId = torch.LongTensor{testData[idx][1]}
        }
    end
}
]]


local model = require("models/".. opt.model)
local engine = tnt.OptimEngine()
local meter = tnt.AverageValueMeter()
local criterion = nn.CrossEntropyCriterion()-- nn.MSECriterion() 
local clerr = tnt.ClassErrorMeter{topk = {1}}
local timer = tnt.TimeMeter()
local batch = 1
model:cuda()
criterion:cuda()

-- print(model)

engine.hooks.onStart = function(state)
    meter:reset()
    clerr:reset()
    timer:reset()
    batch = 1
    if state.training then
        mode = 'Train'
    else
        mode = 'Val'
    end
end


local input  = torch.CudaTensor()
local target = torch.CudaTensor()
engine.hooks.onSample = function(state)
  input:resize( 
      state.sample.input:size()
  ):copy(state.sample.input)
  state.sample.input  = input
  if state.sample.target then
      target:resize( state.sample.target:size()):copy(state.sample.target)
      state.sample.target = target
  end 
end


engine.hooks.onForwardCriterion = function(state)
    meter:add(state.criterion.output)
    clerr:add(state.network.output, state.sample.target)
	-- print(state.sample.target,state.network.output)
    if opt.verbose == true then
        print(string.format("%s Batch: %d/%d; avg. loss: %2.4f; avg. error: %2.4f",
                mode, batch, state.iterator.dataset:size(), meter:value())) -- , clerr:value{k = 1}))
    else
        xlua.progress(batch, state.iterator.dataset:size())
    end
    batch = batch + 1 -- batch increment has to happen here to work for train, val and test.
    timer:incUnit()
end

engine.hooks.onEnd = function(state)
    print(string.format("%s: avg. loss: %2.4f; avg. error: %2.4f, time: %2.4f",
    mode, meter:value(), clerr:value{k = 1}, timer:value()))
end

local epoch = 1

while epoch <= opt.nEpochs do
    trainDataset:select('train')
    engine:train{
        network = model,
        criterion = criterion,
        iterator = getIterator(trainDataset),
        optimMethod = optim.sgd,
        maxepoch = 1,
        config = {
            learningRate = opt.LR,
        	momentum = 1, -- opt.momentum,
		learningRateDecay = .01,
		weightDecay = .001
        }
    }

    trainDataset:select('val')
    engine:test{
        network = model,
        criterion = criterion,
        iterator = getIterator(trainDataset)
    }
    print('Done with Epoch '..tostring(epoch))
    epoch = epoch + 1
end

local submission = assert(io.open(opt.logDir .. "/submission.csv", "w"))
submission:write("Filename,ClassId\n")
batch = 1


engine.hooks.onForward = function(state)
    local fileNames  = state.sample.sampleId
    local _, pred = state.network.output:max(2)
    pred = pred - 1
    for i = 1, pred:size(1) do
        submission:write(string.format("%05d,%d\n", fileNames[i][1], pred[i][1]))
    end
    xlua.progress(batch, state.iterator.dataset:size())
    batch = batch + 1
end

engine.hooks.onEnd = function(state)
    submission:close()
end

engine:test{
    network = model,
    iterator = getIterator(testDataset)
}

print("The End!")
