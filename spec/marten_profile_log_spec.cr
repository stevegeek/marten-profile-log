require "./spec_helper"

describe MartenProfileLog do
  it "has a version" do
    MartenProfileLog::VERSION.should eq("0.1.1")
  end

  it "is disabled when PROFILE is unset" do
    MartenProfileLog.enabled?.should be_false
  end

  it "checkpoint returns the block value when disabled" do
    MartenProfileLog.checkpoint("noop") { 41 + 1 }.should eq(42)
  end

  it "start / record_pool_call are safe no-ops when disabled" do
    MartenProfileLog.start
    MartenProfileLog.record_pool_call(1.0, 2.0)
  end

  it "defines the middleware as a Marten::Middleware subclass" do
    (MartenProfileLog::Middleware < Marten::Middleware).should be_true
  end
end
