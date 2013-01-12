describe "Float" do
  it "#to_f" do
    # issue 165
    1234567890.to_f.to_i.should == 1234567890
  end

  it "Time.now and NSDate" do
    # issue 275
    start = Time.now.to_f
    sleep 0.2
    (NSDate.date.timeIntervalSince1970 - start).should != 0
  end

  it "/" do
    # issue 214, 362, 409
    (288338838383383 / 1000.0).to_i.should == 288338838383
    (89.0 / 100.0 * 100.0).to_i.should == 89
  end

  it "step" do
    # issue 425
    1356890400.step(1356908032.0, 7200.0).to_a.should == [1356890400.0, 1356897600.0, 1356904800.0]
  end

  it "NSDecimalNumber.decimalNumberWithMantissa" do
    # issue 427
    number = NSDecimalNumber.decimalNumberWithMantissa(3000000000, exponent: 0,isNegative: false)
    number.should == 3000000000
  end

  it "Marshal" do
    # issue 430
    flt = 199 / 100.0
    (Marshal.load(Marshal.dump(flt)) * 100.0).to_i.should == 199
  end

  it "Range#eql?" do
    (0.5..2.4).eql?(0.5..2.4).should == true
  end

  it "fixfloat" do
    # in 32bit env, integral multiple become to fixfloat
    100.times do |i|
      i.to_f.__fixfloat__?.should == true
    end

    0.7.step(100.0, 1.0) do |f|
      f.__fixfloat__?.should == false
    end
  end
end