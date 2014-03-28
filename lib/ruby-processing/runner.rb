require 'ostruct'
require 'fileutils'
require 'rbconfig'
require_relative 'config'
require_relative 'version'


module Processing

  # Utility class to handle the different commands that the 'rp5' command
  # offers. Able to run, watch, live, create, app, and unpack
  class Runner
    HELP_MESSAGE = <<-EOS
  Version: #{RubyProcessing::VERSION}

  Ruby-Processing is a little shim between Processing and JRuby that helps
  you create sketches of code art.

  Usage:
    rp5 [run | watch | live | create [width height] | app | unpack] path/to/sketch

    run:        run sketch once
    watch:      watch for changes on the file and relaunch it on the fly
    live:       launch sketch and give an interactive IRB shell
    create:     create new sketch. Use --bare to generate simpler sketches without a class
    app:        create an application version of the sketch
    unpack:     unpack samples or library
    bundle:     Runs `bundle install` using the vendored jarred jruby

  Common options:
    --nojruby:  do not use the installed version of jruby, instead use our vendored
                jarred one (required for shader sketches, and some others).
    --bundler: Load bundler environment (has no effect when using system jruby)

  Configuration file:
    A YAML configuration file is located at {Processing::CONFIG_FILE_PATH}
    
    Possible options are:

      java_args:        pass additionnals arguments to Java VM upon launching. 
                        Useful for increasing available memory (for example:
                        -Xms256m -Xmx256m) or force 32 bits mode (-d32).
      sketchbook_path:  specify Processing sketchbook path to load additionnal 
                        libraries

  Examples:
    rp5 unpack samples
    rp5 run samples/contributed/jwishy.rb
    rp5 create some_new_sketch 640 480
    rp5 create some_new_sketch --p3d 640 480
    rp5 watch some_new_sketch.rb
    rp5 bundle
    rp5 run sketch.rb --nojruby --bundler

  Everything Else:
    http://wiki.github.com/jashkenas/ruby-processing

      EOS

    # Start running a ruby-processing sketch from the passed-in arguments
    def self.execute
      runner = self.new
      runner.parse_options(ARGV)
      runner.execute!
    end

    # Dispatch central.
    def execute!
      case @options.action
      when 'run'    then run(@options.path, @options.args)
      when 'watch'  then watch(@options.path, @options.args)
      when 'live'   then live(@options.path, @options.args)
      when 'create' then create(@options.path, @options.args, @options.p3d)
      when 'app'    then app(@options.path)
      when 'unpack' then unpack(@options.path)
      when 'bundle' then bundle_install
      when /-v/     then show_version
      when /-h/     then show_help
      else
        show_help
      end
    end

    # Parse the command-line options. Keep it simple.
    def parse_options(args)
      @options = OpenStruct.new
      @options.p3d   = !!args.delete('--p3d')
      @options.jruby  = !!args.delete('--jruby')
      @options.nojruby  = !!args.delete('--nojruby')
      @options.action = args[0]     || nil
      @options.path   = args[1]     || File.basename(Dir.pwd + '.rb')
      @options.args   = args[2..-1] || []
    end

    # Create a fresh Ruby-Processing sketch, with the necessary
    # boilerplate filled out.
    def create(sketch, args, p3d)
      Processing::Creator.new.create!(sketch, args, p3d)
    end

    # Just simply run a ruby-processing sketch.
    def run(sketch, args)
      ensure_exists(sketch)
      spin_up('run.rb', sketch, args)
    end

    # Run a sketch, keeping an eye on it's file, and reloading
    # whenever it changes.
    def watch(sketch, args)
      ensure_exists(sketch)
      spin_up('watch.rb', sketch, args)
    end

    # Run a sketch, opening its guts to IRB, letting you play with it.
    def live(sketch, args)
      ensure_exists(sketch)
      spin_up('live.rb', sketch, args)
    end

    # Generate a cross-platform application of a given Ruby-Processing sketch.
    def app(sketch)
      Processing::ApplicationExporter.new.export!(sketch)
    end

    # Install the included samples to a given path, where you can run and
    # alter them to your heart's content.
    def unpack(dir)
      require 'fileutils'
      usage = "Usage: rp5 unpack [samples | library]"
      puts usage and return unless dir.match(/\A(samples|library)\Z/)
      FileUtils.cp_r("#{RP5_ROOT}/#{dir}", "#{Dir.pwd}/#{dir}")
    end

    # Display the current version of Ruby-Processing.
    def show_version
      puts "Ruby-Processing version #{RubyProcessing::VERSION}"
    end

    # Show the standard help/usage message.
    def show_help
      puts HELP_MESSAGE
    end


    private

    # Trade in this Ruby instance for a JRuby instance, loading in a
    # starter script and passing it some arguments.
    # Unless --nojruby is passed, use the installed version of jruby, instead of
    # our vendored jarred one (vendored version is required for some sketches eg shaders).
    def spin_up(starter_script, sketch, args)
      runner = "#{RP5_ROOT}/lib/ruby-processing/runners/#{starter_script}"
      java_args = discover_java_args(sketch)
      warn("The --jruby flag is no longer required") if @options.jruby
      command = @options.nojruby ?
        [
          "GEM_HOME=#{gem_home}", "GEM_PATH=#{gem_home}", #vendor/gem_home is where gems are
          'java', java_args, '-cp', jruby_complete, 'org.jruby.Main', runner, sketch, args
        ].flatten :
        ['jruby', java_args, runner, sketch, args].flatten
      exec command.join(' ')
      # exec replaces the Ruby process with the JRuby one.
    end

    def bundle_install
      system("GEM_HOME=#{gem_home} GEM_PATH=#{gem_home} " +
        "java -jar #{jruby_complete} -S bundle install")
    end

    # If you need to pass in arguments to Java, such as the ones on this page:
    # http://docs.oracle.com/javase/1.5.0/docs/tooldocs/windows/java.html
    # then type them into a java_args.txt in your data directory next to your sketch.
    def discover_java_args(sketch)
      arg_file = "#{File.dirname(sketch)}/data/java_args.txt"
      args = []
      args += dock_icon
      if File.exist?(arg_file)
        args += File.read(arg_file).split(/\s+/)
      elsif Processing::CONFIG["java_args"]
        args += Processing::CONFIG["java_args"].split(/\s+/)
      end
      args.map! {|arg| "-J#{arg}" } unless @options.nojruby
      args
    end

    def ensure_exists(sketch)
      puts "Couldn't find: #{sketch}" and exit unless File.exist?(sketch)
    end

    def jruby_complete
      rcomplete = File.join(RP5_ROOT, 'lib/ruby/jruby-complete.jar')
      if File.exist?(rcomplete)
        return rcomplete
      else
	warn "#{rcomplete} does not exist\nTry running `install_jruby_complete`"
	exit
      end	      
    end

    def gem_home
      File.join(RP5_ROOT, 'vendors/gem_home')
    end

    # On the Mac, we can display a fat, shiny ruby in the Dock.
    def dock_icon
      mac ||= RbConfig::CONFIG['host_os'].match(/darwin/i) 
      mac ||= RbConfig::CONFIG['host_os'].match(/mac/i) 
      mac ? ["-Xdock:name=Ruby-Processing", "-Xdock:icon=#{RP5_ROOT}/lib/templates/application/Contents/Resources/sketch.icns"] : []
    end

  end # class Runner

end # module Processing
