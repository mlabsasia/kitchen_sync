require 'fileutils'
require 'net/http'
require 'pp' # **

class KitchenSyncSpawner
  STARTUP_TIMEOUT = 10 # seconds
  
  attr_reader :program_binary, :capture_stderr_in
  
  def initialize(program_binary, program_args, program_env, options = {})
    @program_binary = program_binary
    @program_args = program_args
    @program_env = program_env
    @capture_stderr_in = options[:capture_stderr_in]
    raise "Can't see a program binary at #{program_binary}" unless File.executable?(program_binary)
  end
  
  def start_binary
    exec_args = [@program_binary] + @program_args
    
    if ENV['VALGRIND']
      exec_args.unshift "--leak-check=full" if ENV['VALGRIND'] == "full"
      exec_args.unshift "valgrind"
      @capture_stderr_in = nil
    end

    if ENV['OS_X_MALLOC_CHECKS']
      ENV['MallocStackLogging'] = '1'
      ENV['MallocScribble'] = '1'
      ENV['MallocPreScribble'] = '1'
      ENV['MallocGuardEdges'] = '1'
      ENV['MallocCheckHeapStart'] = '1'
      ENV['MallocCheckHeapEach'] = '1'
      @capture_stderr_in = nil
    end
    
    stdin_r, stdin_w = IO.pipe
    stdout_r, stdout_w = IO.pipe
    options = {in: stdin_r, out: stdout_w, close_others: true}
    options[:err] = [@capture_stderr_in, "wb"] if @capture_stderr_in
    @child_pid = spawn(@program_env, *exec_args, options)
    stdin_r.close
    stdout_w.close
    @program_stdin = stdin_w
    @program_stdout = stdout_r
  end
  
  def stop_binary
    return unless @child_pid
    Process.kill('TERM', @child_pid) if @child_pid
    @program_stdin.close unless @program_stdin.closed?
    @program_stdout.close
    wait
    @unpacker = nil
  end

  def wait
    Process.wait(@child_pid) if @child_pid
    @child_pid = nil
  end

  def stderr_contents
    File.read(@capture_stderr_in).chomp if @capture_stderr_in
  end

  def expect_stderr(contents)
    @expected_stderr_contents = contents if @capture_stderr_in
    yield
  ensure
    if stderr_contents != @expected_stderr_contents
      fail "Unexpected stderr output: #{stderr_contents.inspect}; should be #{@expected_stderr_contents.inspect}"
    end
    @expected_stderr_contents = nil
  end

  def expected_stderr_contents
    @expected_stderr_contents || "" if @capture_stderr_in
  end

  def read_from_program
    @program_stdout.read
  end

  def unpacker
    @unpacker ||= MessagePack::Unpacker.new(@program_stdout)
  end

  def unpack_next
    unpacker.read.tap do |result|
      if result.is_a?(Array)
        result.each_with_index {|argument, i| result[i] = argument.force_encoding("ASCII-8BIT") if argument.is_a?(String)}
      end
    end
  end

  def read_command
    results = [unpacker.read] # first we receive a verb
    loop do
      args = unpack_next # then 1 or more arrays
      if args != [] # terminated by an empty array, which we don't need to return
        results << args # we return all the other arrays
      elsif !@expected_stderr_contents && !ENV['IGNORE_NONEMPTY_STDERR'] && stderr_contents && stderr_contents != "" # check stderr before returning the results
        fail "Unexpected stderr output: #{stderr_contents.inspect} (results were #{results.inspect})"
      else # all done
        return results
      end
    end
  rescue EOFError
    fail "Unexpected EOF reading command; stderr output: #{stderr_contents.inspect}"
  end

  def send_command(verb, *args)
    @program_stdin.write(verb.to_msgpack)
    send_results(*args)
  end

  def send_results(*results)
    results.each {|result| @program_stdin.write(result.to_msgpack)}
    @program_stdin.write([].to_msgpack)
  end

  def quit
    send_command(Commands::QUIT)
  end
end
