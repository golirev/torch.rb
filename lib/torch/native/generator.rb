require "yaml"
# use require_relative for
# rake generate:function (without bundle)
require_relative "function"

module Torch
  module Native
    module Generator
      class << self
        def generate_cpp_functions
          functions = grouped_functions
          generate_cpp_file("torch", :define_singleton_method, functions[:torch])
          generate_cpp_file("tensor", :define_method, functions[:tensor])
          generate_cpp_file("nn", :define_singleton_method, functions[:nn])
        end

        def grouped_functions
          functions = functions()

          # skip functions
          skip_binding = ["unique_dim_consecutive", "einsum", "normal"]
          skip_args = ["bool[3]", "Dimname", "MemoryFormat", "Layout", "Storage", "ConstQuantizerPtr"]

          # remove functions
          functions.reject! do |f|
            f.ruby_name.start_with?("_") ||
            f.ruby_name.end_with?("_backward") ||
            skip_binding.include?(f.ruby_name) ||
            f.args.any? { |a| a[:type].include?("Dimname") }
          end

          # separate out into todo
          todo_functions, functions =
            functions.partition do |f|
              f.args.any? do |a|
                a[:type].include?("?") && !["Tensor?", "Generator?", "int?", "ScalarType?"].include?(a[:type]) ||
                skip_args.any? { |sa| a[:type].include?(sa) }
              end
            end

          # generate additional functions for optional arguments
          # there may be a better way to do this
          optional_functions, functions = functions.partition { |f| f.args.any? { |a| a[:type] == "int?" } }
          optional_functions.each do |f|
            next if f.ruby_name.start_with?("avg_pool") || f.ruby_name == "cross"
            opt_args = f.args.select { |a| a[:type] == "int?" }
            if opt_args.size == 1
              sep = f.name.include?(".") ? "_" : "."
              f1 = Function.new(f.function.merge("func" => f.func.sub("(", "#{sep}#{opt_args.first[:name]}(").gsub("int?", "int")))
              # TODO only remove some arguments
              f2 = Function.new(f.function.merge("func" => f.func.sub(/, int\?.+\) ->/, ") ->")))
              functions << f1
              functions << f2
            end
          end

          # todo_functions.each do |f|
          #   puts f.func
          #   puts
          # end

          nn_functions, other_functions = functions.partition { |f| f.python_module == "nn" }
          torch_functions = other_functions.select { |f| f.variants.include?("function") }
          tensor_functions = other_functions.select { |f| f.variants.include?("method") }

          {torch: torch_functions, tensor: tensor_functions, nn: nn_functions}
        end

        private

        def generate_cpp_file(type, def_method, functions)
          hpp_template = <<-TEMPLATE
// generated by rake generate:functions
// do not edit by hand

#pragma once

void add_%{type}_functions(Module m);
        TEMPLATE

          cpp_template = <<-TEMPLATE
// generated by rake generate:functions
// do not edit by hand

#include <torch/torch.h>
#include <rice/Module.hpp>
#include "templates.hpp"

void add_%{type}_functions(Module m) {
  m
  %{functions};
}
        TEMPLATE

          cpp_defs = []
          functions.sort_by(&:cpp_name).each do |func|
            fargs = func.args.select { |a| a[:type] != "Generator?" }

            cpp_args = []
            fargs.each do |a|
              t =
                case a[:type]
                when "Tensor"
                  "const Tensor &"
                when "Tensor?"
                  # TODO better signature
                  "OptionalTensor"
                when "ScalarType?"
                  "OptionalScalarType"
                when "Tensor[]"
                  "TensorList"
                when "int"
                  "int64_t"
                when "float"
                  "double"
                when /\Aint\[/
                  "IntArrayRef"
                when /Tensor\(\S!?\)/
                  "Tensor &"
                else
                  a[:type]
                end

              t = "MyReduction" if a[:name] == "reduction" && t == "int64_t"
              cpp_args << [t, a[:name]].join(" ").sub("& ", "&")
            end

            dispatch = func.out? ? "#{func.base_name}_out" : func.base_name
            args = fargs.map { |a| a[:name] }
            args.unshift(*args.pop(func.out_size)) if func.out?
            args.delete("self") if def_method == :define_method

            prefix = def_method == :define_method ? "self." : "torch::"

            body = "#{prefix}#{dispatch}(#{args.join(", ")})"
            # TODO check type as well
            if func.ret_size == 2
              body = "tensor_tuple(#{body})"
            end

            cpp_defs << ".#{def_method}(
    \"#{func.cpp_name}\",
    *[](#{cpp_args.join(", ")}) {
      return #{body};
    })"
          end

          hpp_contents = hpp_template % {type: type}
          cpp_contents = cpp_template % {type: type, functions: cpp_defs.join("\n  ")}

          path = File.expand_path("../../../ext/torch", __dir__)
          File.write("#{path}/#{type}_functions.hpp", hpp_contents)
          File.write("#{path}/#{type}_functions.cpp", cpp_contents)
        end

        def functions
          @native_functions ||= YAML.load_file(path).map { |f| Function.new(f) }
        end

        def path
          File.expand_path("native_functions.yaml", __dir__)
        end
      end
    end
  end
end
